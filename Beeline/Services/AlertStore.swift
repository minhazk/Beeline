import Foundation
import Observation
import Security
import UIKit
@preconcurrency import UserNotifications

/// Your alerts, kept on the phone and mirrored to an alerts server (worker/) with this phone's
/// push token, so the server can tell you about trouble while the app is closed. With no server
/// (none built in, none entered in Settings) alerts are off: no requests, no push registration.
@MainActor @Observable
final class AlertStore {
    static let shared = AlertStore()

    private(set) var alerts: [RouteAlert] {
        didSet {
            delivery = RouteAlert.Delivery(alerts)
            save()
        }
    }
    private(set) var delivery: RouteAlert.Delivery
    var canAddWatch: Bool { alerts.count < RouteAlert.maxAlerts }

    /// What TfL says about each alert, by id, from the server.
    private(set) var status: [String: AlertStatus.Entry] = [:]
    /// Alerts the last finished check couldn't get TfL's answer for.
    private(set) var unchecked: Set<String> = []
    /// A check is on its way.
    private(set) var isChecking = false
    private(set) var checkedAt: Date?
    private(set) var statusProblem: String?
    private(set) var syncProblem: String?
    private(set) var cleanupProblem: String?
    private(set) var permission: UNNotificationSettings?
    /// Set when you tap one of these notifications.
    var showAlerts = false

    /// What the store reads and writes outside itself; tests give their own.
    struct Dependencies {
        var secrets: any SecretStore = SystemKeychain()
        var defaults: UserDefaults = .standard
        var builtInURL: String? = AlertStore.builtInURL
        var builtInToken: String? = Bundle.main.object(forInfoDictionaryKey: "BeelineAlertsToken") as? String
        var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = AlertStore.boundedFetch
        var fillRandomBytes: @Sendable (inout [UInt8]) -> OSStatus = { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        }
        /// How long sync waits for more edits before sending.
        var syncDelay: Duration = .milliseconds(400)
        /// Asks for notifications and a push token.
        var registerForPush: @MainActor () async -> UNNotificationSettings? = {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let settings = await center.notificationSettings()
            // Not allowed: no push token is asked for, so there is none to send anywhere.
            if AlertStore.mayNotify(settings.authorizationStatus) { UIApplication.shared.registerForRemoteNotifications() }
            return settings
        }
        /// The notification settings now, and whether Beeline may notify; tests give their own.
        var notificationSettings: @MainActor () async -> (settings: UNNotificationSettings?, status: UNAuthorizationStatus?) = {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return (settings, settings.authorizationStatus)
        }
        /// Asks iOS for this phone's push token, which comes back through `didRegister`.
        var requestPushToken: @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
    }

    nonisolated static func mayNotify(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }

    private let deps: Dependencies
    private var defaults: UserDefaults { deps.defaults }
    private var token: String? { didSet { defaults.set(token, forKey: "alerts.token") } }
    /// The push-to-start token for the next-train Live Activity, so a saved line can start one
    /// at its travel times (NextTrains).
    private var startToken: String? { didSet { defaults.set(startToken, forKey: "alerts.startToken") } }
    /// The token the server last heard, to forget it when the phone gets a new one.
    private var registered: String? { didSet { defaults.set(registered, forKey: "alerts.registered") } }
    /// Tokens the server may hold besides `registered`: each one sent to it to register, kept from
    /// before it is sent (its answer may never come back), and each one being removed, until the
    /// server says it has gone. All of them are what's removed, however many times the token changed.
    private var maybeHeld: Set<String> { didSet { defaults.set(maybeHeld.sorted(), forKey: "alerts.attempted") } }
    /// The address `registered` and `maybeHeld` were sent to. They are that server's: a later
    /// launch with another server in use (a built-in address changed between releases) doesn't
    /// send them there.
    private var heldBy: String? { didSet { defaults.set(heldBy, forKey: "alerts.heldBy") } }
    private var needsUnregister: Bool { didSet { defaults.set(needsUnregister, forKey: "alerts.needsUnregister") } }
    /// When the server in use first answered a removal that its invitation isn't one it takes.
    /// That may be a mistake put right within the day the server gives a missing invitation, so
    /// the removal is asked again for two; after that the server has removed the phone itself.
    private var refusedSince: Date? { didSet { defaults.set(refusedSince, forKey: "alerts.refusedSince") } }
    private static let refusalPatience: TimeInterval = 2 * 24 * 3600
    private var syncing: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// Counts checks, so one that was replaced can't say the newer one has finished.
    private var statusRun = 0

    /// The server in use: one entered in Settings (Keychain), else the one built in. Nil until
    /// the Keychain could be read: a locked phone means wait, never another server.
    private(set) var server: AlertServer?
    private var serverLoaded = false
    private var changingServer = false
    var isConfigured: Bool { server != nil }
    /// An address entered in Settings, even one that doesn't pass (then alerts are off).
    var enteredURL: String { choice.url }

    nonisolated static let builtInURL = Bundle.main.object(forInfoDictionaryKey: "BeelineAlertsURL") as? String
    static var hasBuiltInServer: Bool {
        AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: builtInURL,
                            builtInToken: Bundle.main.object(forInfoDictionaryKey: "BeelineAlertsToken") as? String) != nil
    }
    static let urlAccount = "alerts.server.url", tokenAccount = "alerts.server.token"
    static let choiceAccount = "alerts.server.choice"
    /// Store an empty choice on reset so even a stale pair of legacy items cannot revive it.
    private struct ServerChoice: Codable {
        var url = ""
        var token = ""
        var legacySecretOwner: URL?
        var removals: [Removal] = []
        /// The server this phone last registered with, invitation and all: what can remove that
        /// registration if a later launch finds another server in use.
        var held: AlertServer?
    }
    /// The credentials needed to remove a specific former registration live in the same
    /// Keychain item as the new choice, until that server acknowledges its deletion.
    private struct Removal: Codable, Equatable {
        let server: AlertServer
        let pushToken: String
        /// When it was first owed (absent on ones kept by earlier builds).
        var since: Date?

        static func == (a: Removal, b: Removal) -> Bool { a.server == b.server && a.pushToken == b.pushToken }
    }
    /// A former server that answers that this phone is another install's, or that the address is
    /// no longer there, has nothing of this phone's left to remove. One that keeps answering
    /// anything else (an invitation it no longer takes, say) is given up on after a month. Either
    /// way it stops being sent this phone's credentials at every launch. A server that can't be
    /// reached is tried for longer (`removalLimit`), since most of those failures send it nothing.
    private static let settledRemovals: Set<Int> = [403, 404, 410]
    private static let removalPatience: TimeInterval = 30 * 24 * 3600
    /// A server that takes the connection and never answers has still been sent the credentials:
    /// after three months of that, too, it is left alone.
    private static let removalLimit: TimeInterval = 90 * 24 * 3600

    /// Whether Beeline may notify, once known.
    private var authorization: UNAuthorizationStatus?
    /// Notifications not allowed for Beeline (turned off, or never agreed to): the server has
    /// nothing it could send this phone, so it isn't registered there, and a registration from
    /// before is removed. Checking your lines' status in the app still asks the server about them.
    private var pushOff: Bool { authorization.map { !Self.mayNotify($0) } ?? false }
    private var choice = ServerChoice()
    private var cleanup: Task<String?, Never>?

    #if DEBUG
    static let environment = "sandbox"
    #else
    static let environment = "production"
    #endif

    init(_ deps: Dependencies = Dependencies()) {
        self.deps = deps
        let saved = deps.defaults.data(forKey: "alerts").flatMap { try? JSONDecoder().decode([RouteAlert].self, from: $0) } ?? []
        alerts = saved
        delivery = RouteAlert.Delivery(saved)
        token = deps.defaults.string(forKey: "alerts.token")
        startToken = deps.defaults.string(forKey: "alerts.startToken")
        registered = deps.defaults.string(forKey: "alerts.registered")
        maybeHeld = Set(deps.defaults.stringArray(forKey: "alerts.attempted") ?? deps.defaults.string(forKey: "alerts.attempted").map { [$0] } ?? [])
        heldBy = deps.defaults.string(forKey: "alerts.heldBy")
        refusedSince = deps.defaults.object(forKey: "alerts.refusedSince") as? Date
        needsUnregister = deps.defaults.bool(forKey: "alerts.needsUnregister")
        loadServer()
    }

    /// Reads the entered server; if the Keychain can't be read now, leaves alerts idle to try again.
    private func loadServer() {
        switch deps.secrets.read(Self.choiceAccount) {
        case .unreadable: return
        case .value(let encoded):
            guard let stored = try? JSONDecoder().decode(ServerChoice.self, from: Data(encoded.utf8)) else {
                serverLoaded = true
                syncProblem = "Couldn't read the saved alert server. Enter its address and token again in Settings."
                return
            }
            choice = stored
            // A removal owed to an address this build wouldn't accept (plain http to localhost,
            // saved by a development build) is never sent this phone's credentials.
            choice.removals.removeAll { (try? AlertServer.address($0.server.url.absoluteString)) == nil }
            // One kept by an earlier build has no date: it starts counting from now, so it too
            // is given up on in the end.
            if choice.removals.contains(where: { $0.since == nil }) {
                var dated = choice
                for index in dated.removals.indices where dated.removals[index].since == nil { dated.removals[index].since = .now }
                if !persist(dated) { choice = dated }
            }
        case .notFound:
            let url = deps.secrets.read(Self.urlAccount), token = deps.secrets.read(Self.tokenAccount)
            guard url != .unreadable, token != .unreadable else { return }
            choice.url = url.value ?? ""
            choice.token = token.value ?? ""
            choice.legacySecretOwner = AlertServer.resolve(enteredURL: choice.url, enteredToken: choice.token,
                                                          builtInURL: deps.builtInURL, builtInToken: deps.builtInToken)?.url
        }
        server = AlertServer.resolve(enteredURL: choice.url, enteredToken: choice.token,
                                     builtInURL: deps.builtInURL, builtInToken: deps.builtInToken)
        serverLoaded = true
        // What was registered was registered with the server then in use. If this launch's is
        // another (a built-in address changed between releases), none of it is this one's to be
        // told about: it is owed its removal by the server that has it, with that server's own
        // invitation, where that is still known.
        // The first launch of a build that keeps `maybeHeld`: an earlier one may have registered
        // this phone's token and been closed before it could note that it had, so the token it
        // left is taken as one the server may hold. Once.
        if !defaults.bool(forKey: "alerts.tracksHeld") {
            defaults.set(true, forKey: "alerts.tracksHeld")
            if registered == nil, maybeHeld.isEmpty, heldBy == nil, server != nil, let token { maybeHeld = [token] }
        }
        if let heldBy, heldBy != server?.url.absoluteString {
            if let held = choice.held, held.url.absoluteString == heldBy, (try? AlertServer.address(heldBy)) != nil {
                var owed = choice
                var tokens = maybeHeld
                if let registered { tokens.insert(registered) }
                for pushToken in tokens.sorted() {
                    let removal = Removal(server: held, pushToken: pushToken, since: .now)
                    if !owed.removals.contains(removal) { owed.removals.append(removal) }
                }
                owed.held = nil
                if !persist(owed) { choice = owed }
            }
            forgetRegistration()
        }
    }

    /// Notes which server (and invitation) is about to be sent this phone's registration.
    private func noteHolder(_ server: AlertServer) {
        heldBy = server.url.absoluteString
        guard choice.held != server else { return }
        var updated = choice
        updated.held = server
        if !persist(updated) { choice = updated }
    }

    private func forgetRegistration() {
        refusedSince = nil
        registered = nil
        maybeHeld = []
        heldBy = nil
        needsUnregister = false
    }

    private func persist(_ next: ServerChoice) -> Bool {
        guard let data = try? JSONEncoder().encode(next),
              deps.secrets.write(String(decoding: data, as: UTF8.self), for: Self.choiceAccount) else { return false }
        choice = next
        return true
    }

    /// For tests: until pending cleanup and sync have gone out.
    func waitForSync() async {
        _ = await cleanup?.value
        await syncing?.value
    }

    /// The server, once the Keychain has been read.
    private func currentServer() -> AlertServer? {
        if !serverLoaded {
            loadServer()
            // Read at last (the phone was locked at launch): removals it was holding, or that
            // reading it has just found owed, start now rather than at the next launch.
            if serverLoaded, !changingServer { _ = retryRemovals() }
        }
        return serverLoaded ? server : nil
    }

    private var builtInAddress: URL? { deps.builtInURL.flatMap { try? AlertServer.address($0) } }

    /// This install's own secret for a server: it lets only the install that registered a phone
    /// change, test or remove it. Random, kept in the Keychain, never shown; one per address.
    /// The built-in server's from earlier builds is carried over, so those phones stay theirs.
    /// A Keychain that can't be read now means no request, never a new secret.
    func deviceSecret(for server: AlertServer) throws -> String {
        let account = server.secretAccount
        switch deps.secrets.read(account) {
        case .value(let saved) where saved.count >= 32: return saved
        case .unreadable: throw AlertError.keychainLocked
        default: break
        }
        if server.url == choice.legacySecretOwner {
            var oldAccounts = [server.legacyScopedAccount]
            if server.url == builtInAddress { oldAccounts.append(AlertServer.legacySecretAccount) }
            for oldAccount in oldAccounts {
                switch deps.secrets.read(oldAccount) {
                case .value(let legacy) where legacy.count >= 32:
                    guard deps.secrets.write(legacy, for: account) else { throw AlertError.keychainLocked }
                    return legacy
                case .unreadable: throw AlertError.keychainLocked
                default: continue
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard deps.fillRandomBytes(&bytes) == errSecSuccess else { throw AlertError.randomUnavailable }
        let secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // A secret that couldn't be kept would lock this phone out of its own registration later.
        guard deps.secrets.write(secret, for: account) else { throw AlertError.keychainLocked }
        return secret
    }

    // MARK: Choosing the server

    /// Switches to a server entered in Settings, or with an empty address back to the built-in
    /// one (or none). The new choice and any outstanding removals are saved together.
    /// Alerts stay on the phone and are registered with the new server.
    @discardableResult
    func useServer(url: String, token appToken: String) async throws(AlertServer.Problem) -> String? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines), appToken = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: AlertServer?
        if url.isEmpty {
            next = AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: deps.builtInURL, builtInToken: deps.builtInToken)
        } else {
            let address = try AlertServer.address(url)
            guard !appToken.isEmpty else { throw .noToken }
            next = AlertServer(url: address, token: appToken, isBuiltIn: false)
        }
        guard serverLoaded || { loadServer(); return serverLoaded }() else { throw .keychainLocked }
        guard !changingServer else { throw .changeInProgress }
        changingServer = true
        defer { changingServer = false }
        // An already-sent DELETE must finish before its endpoint can become active again.
        _ = await cleanup?.value
        var updated = choice
        updated.url = url
        updated.token = url.isEmpty ? "" : appToken
        // A new address, or a new invitation at the same one: the credentials that can remove what
        // the server holds are the old ones, kept until this phone is registered there again (which
        // is what lets them go, in `sync`) or the removal is answered. An invitation mistyped on
        // the way back must not be all that's left to remove a registration with.
        if let old = server, old.url != next?.url || old.token != next?.token {
            // What that server was told, or may have been: never a token it was never sent.
            var previousTokens = maybeHeld
            if let registered { previousTokens.insert(registered) }
            for previous in previousTokens.sorted() {
                let removal = Removal(server: old, pushToken: previous, since: .now)
                if !updated.removals.contains(removal) { updated.removals.append(removal) }
            }
        }
        guard persist(updated) else { throw .cannotSave }
        deps.secrets.write("", for: Self.urlAccount)
        deps.secrets.write("", for: Self.tokenAccount)
        let oldSync = syncing
        syncing?.cancel()
        statusTask?.cancel()
        if server?.url != next?.url { forgetRegistration() }
        server = next
        status = [:]
        unchecked = []
        checkedAt = nil
        statusProblem = nil
        syncProblem = nil
        cleanupProblem = nil
        await oldSync?.value
        let note = await retryRemovals()?.value
        if next != nil, !delivery.ready.isEmpty {
            await enablePush()
            sync()
            await refreshStatus(force: true)
        }
        return note
    }

    private func retryRemovals() -> Task<String?, Never>? {
        if let cleanup { return cleanup }
        guard !choice.removals.isEmpty else { return nil }
        let task = Task { @MainActor () -> String? in
            defer { cleanup = nil }
            var note: String?
            // Whether this phone will register with a server again decides whether a removal
            // owed to that same server still stands: known before any is let go.
            if authorization == nil { await loadPermission() }
            for removal in choice.removals {
                // A built-in address can also change between releases. The active registration
                // is reconciled by sync(), never by a cleanup job from a previous launch: a
                // removal owed for the token this phone is about to register there again waits,
                // with its credentials, until that registration is made (and lets it go).
                guard removal.server.url != server?.url || removal.pushToken != token || delivery.ready.isEmpty || pushOff else { continue }
                do {
                    do {
                        try Self.acknowledged(try await send("DELETE", path: "devices/\(removal.pushToken)", to: removal.server))
                    } catch AlertError.server(_, let status) where Self.settledRemovals.contains(status) {
                        // Nothing of this phone's is left there to remove.
                    } catch AlertError.server {
                        // It answered, and refused: tried again for a month, then no more.
                        let givenUp = removal.since.map { Date.now.timeIntervalSince($0) > Self.removalPatience } ?? false
                        if !givenUp {
                            note = "Couldn't remove this phone from \(removal.server.label). Beeline will try again next time you open it."
                            continue
                        }
                    } catch {
                        let givenUp = removal.since.map { Date.now.timeIntervalSince($0) > Self.removalLimit } ?? false
                        if !givenUp {
                            note = "Couldn't remove this phone from \(removal.server.label). Beeline will try again next time you open it."
                            continue
                        }
                    }
                }
                var updated = choice
                updated.removals.removeAll { $0 == removal }
                if !persist(updated) { note = "Couldn't update the Keychain. Beeline will check the old registration again next time." }
            }
            cleanupProblem = note
            return note
        }
        cleanup = task
        return task
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(alerts), forKey: "alerts")
    }

    // MARK: Editing

    func saveProblem(for alert: RouteAlert) -> String? {
        if !alerts.contains(where: { $0.id == alert.id }) && !canAddWatch { return "Remove a watch before adding another. The limit is 30." }
        // An edit must leave room for all the other watches that are already being delivered.
        var remaining = delivery.ready.contains { $0.id == alert.id }
            ? RouteAlert.Delivery(delivery.ready.filter { $0.id != alert.id }) : delivery
        return remaining.include(alert)
    }

    @discardableResult func save(_ alert: RouteAlert) -> Bool {
        guard saveProblem(for: alert) == nil else { return false }
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) { alerts[index] = alert } else { alerts.append(alert) }
        status[alert.id] = nil
        unchecked.remove(alert.id)
        needsUnregister = false
        Task {
            await enablePush()
            await refreshStatus(force: true)
        }
        sync()
        return true
    }

    func delete(_ id: RouteAlert.ID) {
        if delivery.ready.count == 1, delivery.ready.first?.id == id, holdsRegistration {
            needsUnregister = true
        }
        alerts.removeAll { $0.id == id }
        status[id] = nil
        unchecked.remove(id)
        // A partial answer's message may name the line just removed.
        if !status.isEmpty { statusProblem = uncheckedProblem(delivery.ready) }
        sync()
    }

    // MARK: Push

    /// Asks once, then registers for a token on every launch (it can change).
    func enablePush() async {
        guard !delivery.ready.isEmpty, currentServer() != nil else { return }
        permission = await deps.registerForPush()
        if let permission { authorization = permission.authorizationStatus }
        if pushOff, holdsRegistration { sync() }
    }

    /// Whenever Beeline comes to the front: notifications may have been turned off, or on, since.
    func refreshPermission() async {
        await loadPermission()
        reconcilePush()
    }

    private func loadPermission() async {
        let current = await deps.notificationSettings()
        permission = current.settings
        authorization = current.status
    }

    /// Whether the server holds, or may hold, a registration of this phone's.
    private var holdsRegistration: Bool { registered != nil || !maybeHeld.isEmpty }

    /// With the permission known: a phone that may no longer be notified is taken off the server;
    /// one that may be (again) and isn't registered asks for its token and registers; and a
    /// removal that didn't get through last time is tried again.
    private func reconcilePush() {
        guard authorization != nil, currentServer() != nil else { return }
        if delivery.ready.isEmpty {
            if holdsRegistration || needsUnregister { sync() }
            return
        }
        if pushOff {
            if holdsRegistration { sync() }
            return
        }
        guard registered == nil || registered != token || !maybeHeld.isEmpty else { return }
        deps.requestPushToken()
        if token != nil { sync() }
    }

    func didRegister(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        sync()
    }

    /// A new push-to-start token: the server needs it before it can start a Live Activity.
    func didGetStartToken(_ hex: String) {
        guard hex != startToken else { return }
        startToken = hex
        if !delivery.ready.isEmpty { sync() }
    }

    func didFailToRegister(_ error: any Error) {
        syncProblem = "This phone couldn't get a push token: \(error.localizedDescription)"
    }

    /// The server's copy follows the phone's; the last change wins.
    private func sync() {
        syncing?.cancel()
        syncing = Task {
            try? await Task.sleep(for: deps.syncDelay)
            // A removal still owed to this same server goes first; ones owed to others (which may
            // take their time, or never answer) don't hold this phone's registration up.
            if choice.removals.contains(where: { $0.server.url == server?.url }) { _ = await cleanup?.value }
            // Whether Beeline may notify decides whether this phone registers at all: known
            // before anything is sent, not found out after.
            if authorization == nil { await loadPermission() }
            guard !Task.isCancelled, let server = currentServer() else { return }
            do {
                var pushesReady = true
                if delivery.ready.isEmpty || pushOff {
                    // What the server holds, or may: never a token it was never sent.
                    var tokens = maybeHeld
                    if let registered { tokens.insert(registered) }
                    // Until each removal is answered the server may or may not hold the token:
                    // kept as "may" from before it is asked, so an answer that never comes still
                    // leaves it to be removed, and the phone free to register again if it should.
                    if !tokens.isEmpty { noteHolder(server) }
                    maybeHeld = tokens
                    registered = nil
                    for previous in tokens.sorted() {
                        try Task.checkCancellation()
                        try await remove(previous, from: server)
                    }
                    try Task.checkCancellation()
                    needsUnregister = false
                    // A removal the server in use refused for its invitation may still be owed
                    // with the one that was used before: with nothing to register now, it goes.
                    if !changingServer { _ = retryRemovals() }
                } else {
                    guard let token else { return }
                    // Tokens the server holds, or may, from before this phone's token changed.
                    var former = maybeHeld
                    if let registered { former.insert(registered) }
                    former.remove(token)
                    let body = try JSONEncoder().encode(RouteAlert.Registration(environment: Self.environment, timeZone: TimeZone.current.identifier,
                                                                                alerts: delivery.ready.map(RouteAlert.Wire.init), startToken: startToken))
                    noteHolder(server)
                    maybeHeld.insert(token)
                    // The new token first: the server moves this phone's registration to it, so a
                    // refusal (too many requests, TfL not answering) leaves the old one in place
                    // rather than none.
                    let answer: Data
                    do {
                        answer = try await send("PUT", path: "devices/\(token)", body: body, to: server)
                    } catch AlertError.server(_, let status) where status == 409 && !former.isEmpty {
                        // A server from before registrations moved with their phone keeps one phone
                        // to an invitation, and says so without a code: the old token makes room
                        // first. (One that says why, with a code, is `conflict`, and nothing of
                        // this phone's is removed for it.)
                        for old in former.sorted() { try await remove(old, from: server) }
                        try Task.checkCancellation()
                        answer = try await send("PUT", path: "devices/\(token)", body: body, to: server)
                    }
                    pushesReady = try Self.acknowledged(answer).pushes != false
                    try Task.checkCancellation()
                    // The old ones are kept as "may hold" before `registered` moves on from
                    // them, so each stays on record until its own removal is answered.
                    maybeHeld.formUnion(former)
                    registered = token
                    maybeHeld.remove(token)
                    // Registered there again: a removal owed to it for this token is owed no more.
                    if choice.removals.contains(where: { $0.server.url == server.url && $0.pushToken == token }) {
                        var settled = choice
                        settled.removals.removeAll { $0.server.url == server.url && $0.pushToken == token }
                        _ = persist(settled)
                    }
                    for old in former.sorted() {
                        try Task.checkCancellation()
                        try await remove(old, from: server)
                    }
                }
                syncProblem = pushesReady ? nil : "This alert server has no push key yet, so it can't send notifications."
                // Notifications may have been turned back on while a removal was on its way.
                if !Task.isCancelled, authorization != nil, !pushOff, !delivery.ready.isEmpty, registered == nil, token != nil { sync() }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                syncProblem = (error as? AlertError)?.message ?? "Couldn't reach the alert server, so notifications may be out of date. It tries again next time you open the app."
            }
        }
    }

    /// Asks the server in use to forget one of this phone's tokens. An answer that it isn't this
    /// phone's, or isn't there, is as good as done; any other failure leaves it in `maybeHeld`.
    private func remove(_ pushToken: String, from server: AlertServer) async throws {
        var refusedInvitation = false
        do {
            try Self.acknowledged(try await send("DELETE", path: "devices/\(pushToken)", to: server))
        } catch AlertError.server(_, let status) where Self.settledRemovals.contains(status) {
            // Not this phone's, or not there.
        } catch AlertError.server(_, let status) where status == 401 {
            // An invitation the server in use doesn't take: revoked (it removes that phone itself
            // within a day), mistyped (a removal queued with the one used before is what can do
            // it), or left out of the server's list by mistake and soon put back. So it is asked
            // again for two days, and after that no more: the credentials aren't sent for good.
            guard let since = refusedSince, Date.now.timeIntervalSince(since) > Self.refusalPatience else {
                if refusedSince == nil { refusedSince = .now }
                if !changingServer { _ = retryRemovals() }
                throw AlertError.server("The alert server didn't take this phone's invitation, so it couldn't be removed there yet. Beeline will try again.", status: 401)
            }
            refusedInvitation = true
        }
        // An answer to a request this sync was told to drop isn't acted on: a newer one may have
        // put the same token back on record.
        try Task.checkCancellation()
        maybeHeld.remove(pushToken)
        refusedSince = nil
        // Done with this invitation, the same registration is what a removal queued for this
        // address and token was owed (the device secret is the address's): owed no more.
        if !refusedInvitation, choice.removals.contains(where: { $0.server.url == server.url && $0.pushToken == pushToken }) {
            var settled = choice
            settled.removals.removeAll { $0.server.url == server.url && $0.pushToken == pushToken }
            _ = persist(settled)
        }
    }

    /// What a change to a registration answers. A page that merely says 200 (a proxy's, a parked
    /// domain's) isn't the server agreeing to anything.
    struct Acknowledgement: Decodable {
        var ok: Bool?
        var pushes: Bool?
        var status: Int?
    }

    @discardableResult
    nonisolated static func acknowledged(_ data: Data) throws -> Acknowledgement {
        guard let answer = try? JSONDecoder().decode(Acknowledgement.self, from: data), answer.ok == true || answer.status == 200 else {
            throw AlertError.server("The alert server's answer wasn't one Beeline understands. Check its address.", status: 0)
        }
        return answer
    }

    /// On launch: pick up a new token, and resend in case the last change didn't reach the server.
    func resume() {
        let active = currentServer()
        if !changingServer { _ = retryRemovals() }
        guard active != nil else { return }
        if delivery.ready.isEmpty {
            if holdsRegistration || needsUnregister { sync() }
            return
        }
        Task {
            await refreshPermission()
            // Every launch: the token can change, and the last change may not have reached the server.
            if !pushOff { deps.requestPushToken() }
        }
    }

    /// A real notification, sent the way trouble will be.
    func sendTest() async -> String {
        guard let server = currentServer() else { return "No alert server is set." }
        guard let token, registered == token else { return "This phone isn't registered with the alert server yet. Allow notifications, then try again." }
        do {
            try Self.acknowledged(try await send("POST", path: "devices/\(token)/test", to: server))
            return "Sent. It should arrive in a few seconds."
        } catch AlertError.server(let message, _) {
            return message
        } catch {
            return (error as? AlertError)?.message ?? "Couldn't reach the alert server."
        }
    }

    // MARK: Status

    /// What a row shows for one alert.
    enum Verdict: Equatable, Sendable {
        /// Not asked about yet, or being asked about now.
        case checking
        /// The last check couldn't get TfL's answer for it.
        case unavailable
        case ready(AlertStatus.Entry)

        var entry: AlertStatus.Entry? {
            switch self {
            case .ready(let entry): entry
            default: nil
            }
        }
    }

    /// A verdict already in stays up while it's checked again.
    func verdict(for id: String) -> Verdict {
        if let entry = status[id] { return .ready(entry) }
        return unchecked.contains(id) && !isChecking ? .unavailable : .checking
    }

    /// What TfL says now, at most once a minute while every alert has an answer.
    func refreshStatus(force: Bool = false) async {
        guard let server = currentServer() else { return }
        let watched = delivery.ready
        guard !watched.isEmpty else {
            statusTask?.cancel()
            status = [:]
            unchecked = []
            isChecking = false
            checkedAt = nil
            statusProblem = nil
            return
        }
        let ids = Set(watched.map(\.id))
        if !force, let checkedAt, Date.now.timeIntervalSince(checkedAt) < 60, Set(status.keys) == ids { return }
        statusTask?.cancel()
        statusRun += 1
        let run = statusRun
        isChecking = true
        let task = Task {
            defer { if statusRun == run { isChecking = false } }
            do {
                struct Body: Encodable { var alerts: [RouteAlert.Wire]; var timeZone: String }
                let body = try JSONEncoder().encode(Body(alerts: watched.map(RouteAlert.Wire.init), timeZone: TimeZone.current.identifier))
                let result = try AlertStatus.decode(try await send("POST", path: "status", body: body, to: server))
                guard !Task.isCancelled else { return }
                // One the server couldn't check, or left out, gets no verdict rather than an old one.
                let skipped = Set(result.unchecked)
                status = Dictionary(result.alerts.filter { ids.contains($0.id) && !skipped.contains($0.id) }.map { ($0.id, $0) },
                                    uniquingKeysWith: { a, _ in a })
                unchecked = ids.subtracting(status.keys)
                checkedAt = result.checkedAt
                statusProblem = uncheckedProblem(watched)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                // No answer now: an earlier "Good" may no longer be true.
                status = [:]
                unchecked = ids
                statusProblem = (error as? AlertError)?.message ?? "Couldn't check TfL just now."
            }
        }
        statusTask = task
        await task.value
    }

    /// "TfL couldn't check Stratford ⇄ Gants Hill just now. Try again later."
    private func uncheckedProblem(_ watched: [RouteAlert]) -> String? {
        let names = watched.filter { unchecked.contains($0.id) }.map(\.displayName)
        guard !names.isEmpty else { return nil }
        let which = names.count <= 2 ? names.formatted(.list(type: .and)) : "\(names.count) of your lines"
        return "TfL couldn't check \(which) just now. Try again later."
    }

    // MARK: Server

    enum AlertError: Error {
        case server(String, status: Int), keychainLocked, randomUnavailable, tooLarge
        /// A 409 that says which refusal it is (`code`): the registration wasn't made, and nothing
        /// of this phone's on the server stands in its way.
        case conflict(String)

        var message: String? {
            switch self {
            case .server(let message, _), .conflict(let message): message
            case .keychainLocked: "Couldn't access this phone's alert credential in the Keychain. Unlock the phone and try again."
            case .randomUnavailable: "Couldn't generate a secure credential for this phone. Try again."
            default: nil
            }
        }
    }
    /// The most a reply may be: a status for 30 alerts is a few KB.
    nonisolated static let maxResponse = 512 * 1024

    /// One request to the server in use, for the next-train Live Activity; nil without one.
    @discardableResult
    func sendToServer(_ method: String, path: String, body: Data? = nil) async throws -> Data? {
        guard let server = currentServer() else { return nil }
        return try await send(method, path: path, body: body, to: server)
    }

    /// One request to `server`, with its token and, for a phone's own routes, this install's
    /// secret for it. Redirects are refused: the token and secret go to that address only.
    @discardableResult
    func send(_ method: String, path: String, body: Data? = nil, to server: AlertServer) async throws -> Data {
        // Credentials go only to an address this build would take if it were typed in now.
        guard (try? AlertServer.address(server.url.absoluteString)) != nil else {
            throw AlertError.server("This alert server's address isn't one Beeline sends to.", status: 0)
        }
        var request = URLRequest(url: server.url.appending(path: "v1/\(path)"))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if path.hasPrefix("devices/") || path.hasPrefix("activities/") { request.setValue(try deviceSecret(for: server), forHTTPHeaderField: "X-Device-Secret") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTP.appUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await deps.transport(request)
        guard data.count <= Self.maxResponse else { throw AlertError.tooLarge }   // for any transport
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            struct Problem: Decodable { var error: String?; var reason: String?; var code: String? }
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            // The server's own words, kept short: it is whatever address was entered.
            let said = problem?.error ?? problem?.reason.map { "Apple refused it: \($0)" } ?? "The alert server said \(code)."
            // Its words are shown, but never this phone's own credentials echoed back in them,
            // where a screenshot would carry them off.
            let sent = [server.token, request.value(forHTTPHeaderField: "X-Device-Secret")].compactMap { $0 }
                + path.split(separator: "/").map(String.init).filter { $0.count >= 32 }
            // An invitation may be short; anything under four letters would hide ordinary words.
            let echoes = sent.contains { $0.count >= 4 && said.localizedCaseInsensitiveContains($0) }
            let shown = echoes ? "The alert server said \(code)." : String(said.prefix(200))
            if code == 409, problem?.code != nil { throw AlertError.conflict(shown) }
            throw AlertError.server(shown, status: code)
        }
        return data
    }
}

extension AlertStore {
    /// Fetches without following redirects, refusing a reply larger than `maxResponse` from its
    /// Content-Length, or as it arrives, before it is all in memory.
    nonisolated static func boundedFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await HTTP.privateSession.bytes(for: request, delegate: NoRedirects.shared)
        if response.expectedContentLength > Int64(maxResponse) { bytes.task.cancel(); throw AlertError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponse { bytes.task.cancel(); throw AlertError.tooLarge }
        }
        return (data, response)
    }
}

/// Alert requests go to the address given, never on to wherever it points.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Hands push tokens to the alerts.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Also when iOS wakes Beeline in the background for a Live Activity the server started.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NextTrains.shared.resume()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AlertStore.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AlertStore.shared.didFailToRegister(error)
    }
}
