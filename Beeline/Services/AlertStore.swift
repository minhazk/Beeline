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
            UIApplication.shared.registerForRemoteNotifications()
            return await center.notificationSettings()
        }
    }

    private let deps: Dependencies
    private var defaults: UserDefaults { deps.defaults }
    private var token: String? { didSet { defaults.set(token, forKey: "alerts.token") } }
    /// The token the server last heard, to forget it when the phone gets a new one.
    private var registered: String? { didSet { defaults.set(registered, forKey: "alerts.registered") } }
    private var needsUnregister: Bool { didSet { defaults.set(needsUnregister, forKey: "alerts.needsUnregister") } }
    private var syncing: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

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
    }
    /// The credentials needed to remove a specific former registration live in the same
    /// Keychain item as the new choice, until that server acknowledges its deletion.
    private struct Removal: Codable, Equatable {
        let server: AlertServer
        let pushToken: String
    }
    private var choice = ServerChoice()
    private var cleanup: Task<String?, Never>?

    #if DEBUG
    private static let environment = "sandbox"
    #else
    private static let environment = "production"
    #endif

    init(_ deps: Dependencies = Dependencies()) {
        self.deps = deps
        let saved = deps.defaults.data(forKey: "alerts").flatMap { try? JSONDecoder().decode([RouteAlert].self, from: $0) } ?? []
        alerts = saved
        delivery = RouteAlert.Delivery(saved)
        token = deps.defaults.string(forKey: "alerts.token")
        registered = deps.defaults.string(forKey: "alerts.registered")
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
        if !serverLoaded { loadServer() }
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
        if let old = server, old.url != next?.url {
            var previousTokens = Set([registered].compactMap { $0 })
            if syncing != nil || needsUnregister, let token { previousTokens.insert(token) }
            for previous in previousTokens.sorted() {
                let removal = Removal(server: old, pushToken: previous)
                if !updated.removals.contains(removal) { updated.removals.append(removal) }
            }
        }
        if let next, !delivery.ready.isEmpty {
            updated.removals.removeAll { $0.server.url == next.url && $0.pushToken == token }
        }
        guard persist(updated) else { throw .cannotSave }
        deps.secrets.write("", for: Self.urlAccount)
        deps.secrets.write("", for: Self.tokenAccount)
        let oldSync = syncing
        syncing?.cancel()
        statusTask?.cancel()
        if server?.url != next?.url {
            registered = nil
            needsUnregister = false
        }
        server = next
        status = [:]
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
            for removal in choice.removals {
                // A built-in address can also change between releases. The active registration
                // is reconciled by sync(), never by a cleanup job from a previous launch.
                if removal.server.url != server?.url || removal.pushToken != token || delivery.ready.isEmpty {
                    do {
                        try await send("DELETE", path: "devices/\(removal.pushToken)", to: removal.server)
                    } catch {
                        note = "Couldn't remove this phone from \(removal.server.label). Beeline will try again next time you open it."
                        continue
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
        needsUnregister = false
        Task {
            await enablePush()
            await refreshStatus(force: true)
        }
        sync()
        return true
    }

    func delete(_ id: RouteAlert.ID) {
        if delivery.ready.count == 1, delivery.ready.first?.id == id, token != nil || registered != nil {
            needsUnregister = true
        }
        alerts.removeAll { $0.id == id }
        status[id] = nil
        sync()
    }

    // MARK: Push

    /// Asks once, then registers for a token on every launch (it can change).
    func enablePush() async {
        guard !delivery.ready.isEmpty, currentServer() != nil else { return }
        permission = await deps.registerForPush()
    }

    func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings()
    }

    func didRegister(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        sync()
    }

    func didFailToRegister(_ error: any Error) {
        syncProblem = "This phone couldn't get a push token: \(error.localizedDescription)"
    }

    /// The server's copy follows the phone's; the last change wins.
    private func sync() {
        syncing?.cancel()
        syncing = Task {
            try? await Task.sleep(for: deps.syncDelay)
            _ = await cleanup?.value
            guard !Task.isCancelled, let server = currentServer() else { return }
            do {
                if delivery.ready.isEmpty {
                    let tokens = Set([registered, token].compactMap { $0 })
                    for previous in tokens {
                        try Task.checkCancellation()
                        try await send("DELETE", path: "devices/\(previous)", to: server)
                    }
                    try Task.checkCancellation()
                    registered = nil
                    needsUnregister = false
                } else {
                    guard let token else { return }
                    if let old = registered, old != token { try await send("DELETE", path: "devices/\(old)", to: server) }
                    try Task.checkCancellation()
                    let body = RouteAlert.Registration(environment: Self.environment, timeZone: TimeZone.current.identifier,
                                                       alerts: delivery.ready.map(RouteAlert.Wire.init))
                    try await send("PUT", path: "devices/\(token)", body: JSONEncoder().encode(body), to: server)
                    try Task.checkCancellation()
                    registered = token
                }
                syncProblem = nil
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                syncProblem = (error as? AlertError)?.message ?? "Couldn't reach the alert server, so notifications may be out of date. It tries again next time you open the app."
            }
        }
    }

    /// On launch: pick up a new token, and resend in case the last change didn't reach the server.
    func resume() {
        let active = currentServer()
        if !changingServer { _ = retryRemovals() }
        guard active != nil else { return }
        if delivery.ready.isEmpty {
            if registered != nil || needsUnregister { sync() }
            return
        }
        Task { await refreshPermission() }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// A real notification, sent the way trouble will be.
    func sendTest() async -> String {
        guard let server = currentServer() else { return "No alert server is set." }
        guard let token, registered == token else { return "This phone isn't registered with the alert server yet. Allow notifications, then try again." }
        do {
            try await send("POST", path: "devices/\(token)/test", to: server)
            return "Sent. It should arrive in a few seconds."
        } catch AlertError.server(let message) {
            return message
        } catch {
            return (error as? AlertError)?.message ?? "Couldn't reach the alert server."
        }
    }

    // MARK: Status

    /// What TfL says now, at most once a minute.
    func refreshStatus(force: Bool = false) async {
        guard let server = currentServer() else { return }
        let watched = delivery.ready
        guard !watched.isEmpty else {
            statusTask?.cancel()
            status = [:]
            checkedAt = nil
            statusProblem = nil
            return
        }
        if !force, let checkedAt, Date.now.timeIntervalSince(checkedAt) < 60, Set(status.keys) == Set(watched.map(\.id)) { return }
        statusTask?.cancel()
        let task = Task {
            do {
                struct Body: Encodable { var alerts: [RouteAlert.Wire]; var timeZone: String }
                let body = try JSONEncoder().encode(Body(alerts: watched.map(RouteAlert.Wire.init), timeZone: TimeZone.current.identifier))
                let result = try AlertStatus.decode(try await send("POST", path: "status", body: body, to: server))
                guard !Task.isCancelled else { return }
                status = Dictionary(result.alerts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                checkedAt = result.checkedAt
                statusProblem = nil
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if !Task.isCancelled { statusProblem = (error as? AlertError)?.message ?? "Couldn't check TfL just now." }
            }
        }
        statusTask = task
        await task.value
    }

    // MARK: Server

    enum AlertError: Error {
        case server(String), keychainLocked, randomUnavailable, tooLarge

        var message: String? {
            switch self {
            case .server(let message): message
            case .keychainLocked: "Couldn't access this phone's alert credential in the Keychain. Unlock the phone and try again."
            case .randomUnavailable: "Couldn't generate a secure credential for this phone. Try again."
            default: nil
            }
        }
    }
    /// The most a reply may be: a status for 30 alerts is a few KB.
    nonisolated static let maxResponse = 512 * 1024

    /// One request to `server`, with its token and, for a phone's own routes, this install's
    /// secret for it. Redirects are refused: the token and secret go to that address only.
    @discardableResult
    func send(_ method: String, path: String, body: Data? = nil, to server: AlertServer) async throws -> Data {
        var request = URLRequest(url: server.url.appending(path: "v1/\(path)"))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if path.hasPrefix("devices/") { request.setValue(try deviceSecret(for: server), forHTTPHeaderField: "X-Device-Secret") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTP.appUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await deps.transport(request)
        guard data.count <= Self.maxResponse else { throw AlertError.tooLarge }   // for any transport
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            struct Problem: Decodable { var error: String?; var reason: String? }
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            // The server's own words, kept short: it is whatever address was entered.
            let said = problem?.error ?? problem?.reason.map { "Apple refused it: \($0)" } ?? "The alert server said \(code)."
            throw AlertError.server(String(said.prefix(200)))
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
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AlertStore.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AlertStore.shared.didFailToRegister(error)
    }
}
