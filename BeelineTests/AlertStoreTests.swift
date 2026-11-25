import Foundation
import Security
import Testing
@preconcurrency import UserNotifications
@testable import Beeline

/// The alert store against a recorded transport and an in-memory Keychain: which server gets
/// which token and secret, what a locked Keychain does, and what the server's reply may be.
@MainActor
struct AlertStoreTests {
    final class Secrets: SecretStore, @unchecked Sendable {
        var items: [String: String] = [:]
        var locked: Set<String> = []
        var writes: [String] = []
        var failingWrites: Set<String> = []
        func read(_ account: String) -> KeychainRead {
            if locked.contains(account) { return .unreadable }
            return items[account].map { .value($0) } ?? .notFound
        }
        func write(_ value: String, for account: String) -> Bool {
            writes.append(account)
            if failingWrites.contains(account) { return false }
            items[account] = value.isEmpty ? nil : value
            return true
        }
    }

    @MainActor final class Wire {
        var requests: [URLRequest] = []
        var failing: Set<String> = []
        /// What a host answers instead of 200 and `reply`.
        var refusing: [String: (status: Int, body: String)] = [:]
        var reply = Data(#"{"checkedAt":"2026-11-24T12:00:00Z","alerts":[]}"#.utf8)
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            let host = request.url?.host() ?? ""
            if failing.contains(host) { throw URLError(.cannotConnectToHost) }
            if let refusal = refusing[host] {
                return (Data(refusal.body.utf8), HTTPURLResponse(url: request.url!, statusCode: refusal.status, httpVersion: nil, headerFields: nil)!)
            }
            // What the server answers each route: a status to POST status, its agreement to the rest.
            let isStatus = request.httpMethod == "POST" && request.url?.lastPathComponent == "status"
            let isTest = request.httpMethod == "POST" && request.url?.lastPathComponent == "test"
            let answer = isStatus ? reply : agreement ?? Data((isTest ? #"{"status":200,"gone":false}"# : #"{"ok":true,"pushes":true}"#).utf8)
            return (answer, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        /// What a change or a test is answered with, when not the server's usual agreement.
        var agreement: Data?
        func to(_ host: String) -> [URLRequest] { requests.filter { $0.url?.host() == host } }
    }

    static let pushToken = String(repeating: "ab", count: 32)

    static func validAlert() -> RouteAlert {
        var alert = RouteAlert()
        alert.segments = [.init(line: .init(id: "central", name: "Central"), mode: "tube")]
        return alert
    }

    func store(secrets: Secrets = Secrets(), wire: Wire = Wire(), registered: Bool = true,
               builtIn: (String, String)? = ("https://built.example.com", "built-token"),
               defaults existingDefaults: UserDefaults? = nil, permission: Permission = Permission()) -> AlertStore {
        let name = "AlertStoreTests.\(UUID().uuidString)"
        let defaults = existingDefaults ?? UserDefaults(suiteName: name)!
        if defaults.object(forKey: "alerts") == nil {
            defaults.set(true, forKey: "alerts.tracksHeld")
            defaults.set(try! JSONEncoder().encode([Self.validAlert()]), forKey: "alerts")
            defaults.set(Self.pushToken, forKey: "alerts.token")
            if registered { defaults.set(Self.pushToken, forKey: "alerts.registered") }
        }
        var deps = AlertStore.Dependencies()
        deps.secrets = secrets
        deps.defaults = defaults
        deps.builtInURL = builtIn?.0
        deps.builtInToken = builtIn?.1
        deps.transport = { try await wire.send($0) }
        deps.registerForPush = { nil }
        deps.notificationSettings = { (nil, permission.status) }
        deps.requestPushToken = { permission.tokenRequests += 1 }
        deps.syncDelay = .zero
        return AlertStore(deps)
    }

    /// Whether Beeline may notify, as a test sets it; nil is not yet known.
    @MainActor final class Permission {
        var status: UNAuthorizationStatus?
        var tokenRequests = 0
        init(_ status: UNAuthorizationStatus? = nil) { self.status = status }
    }

    @Test func aPhoneThatMayNotBeNotifiedIsTakenOffTheServerAndPutBackWhenItMay() async throws {
        let wire = Wire(), permission = Permission(.denied)
        let store = store(wire: wire, permission: permission)
        await store.refreshPermission()
        await store.waitForSync()
        #expect(wire.requests.map(\.httpMethod) == ["DELETE"], "what the server was told is taken back, and nothing is registered")
        await store.refreshPermission()
        store.didRegister(Data(repeating: 0xcd, count: 32))
        await store.waitForSync()
        #expect(wire.requests.count == 1, "nothing more while it stays off: not even a new token is sent")

        // Turned back on in Settings: no relaunch needed.
        permission.status = .authorized
        await store.refreshPermission()
        await store.waitForSync()
        #expect(permission.tokenRequests == 1)
        #expect(wire.requests.last?.httpMethod == "PUT")
        #expect(wire.requests.last?.url?.lastPathComponent == String(repeating: "cd", count: 32))
        await store.refreshPermission()
        await store.waitForSync()
        #expect(wire.requests.filter { $0.httpMethod == "PUT" }.count == 1, "registered: not sent again each time the app comes forward")
    }

    @Test func aPhoneNeverAskedIsNotRegisteredUntilItAgrees() async throws {
        let wire = Wire(), permission = Permission(.notDetermined)
        let store = store(wire: wire, registered: false, permission: permission)
        store.resume()
        await store.refreshPermission()
        store.didRegister(Data(repeating: 0xab, count: 32))
        await store.waitForSync()
        #expect(wire.requests.isEmpty)
        #expect(permission.tokenRequests == 0)
    }

    @Test func aRemovalStillOwedIsKeptWhenComingBackWithNotificationsOff() async throws {
        let secrets = Secrets(), wire = Wire(), permission = Permission(.authorized)
        let store = store(secrets: secrets, wire: wire, permission: permission)
        wire.failing = ["built.example.com"]
        _ = try await store.useServer(url: "https://mine.example.com", token: "mine-token")
        await store.waitForSync()
        permission.status = .denied
        await store.refreshPermission()
        await store.waitForSync()
        wire.failing = []
        wire.requests = []
        _ = try await store.useServer(url: "", token: "")
        await store.waitForSync()
        #expect(wire.to("built.example.com").map(\.httpMethod).filter { $0 != "POST" } == ["DELETE"], "the built-in server still held this phone")
        #expect(!wire.requests.contains { $0.httpMethod == "PUT" })
    }

    @Test func aNewPushTokenRegistersBeforeTheOldOneIsRemoved() async throws {
        let wire = Wire()
        let store = store(wire: wire)
        store.didRegister(Data(repeating: 0xcd, count: 32))
        await store.waitForSync()
        let calls = wire.requests.map { "\($0.httpMethod ?? "") \(($0.url?.lastPathComponent ?? "").prefix(4))" }
        #expect(calls == ["PUT cdcd", "DELETE abab"], "a refused registration leaves the old one in place, not none")

        // An older server answers that the invitation has a phone: the old token makes room first.
        let older = Wire()
        older.refusing["built.example.com"] = (409, #"{"error":"This invitation already has a phone."}"#)
        let second = self.store(wire: older)
        second.didRegister(Data(repeating: 0xcd, count: 32))
        await second.waitForSync()
        #expect(older.requests.map(\.httpMethod).prefix(2) == ["PUT", "DELETE"])
    }

    @Test func aRegistrationWhoseAnswerNeverCameIsStillTakenBackWhenNotificationsGoOff() async throws {
        let wire = Wire(), permission = Permission(.authorized)
        let store = store(wire: wire, registered: false, permission: permission)
        wire.failing = ["built.example.com"]
        store.didRegister(Data(repeating: 0xab, count: 32))
        await store.waitForSync()
        wire.failing = []
        wire.requests = []
        permission.status = .denied
        await store.refreshPermission()
        await store.waitForSync()
        #expect(wire.requests.map(\.httpMethod) == ["DELETE"], "the server may hold it, so it is asked to forget it")
    }

    @Test func aPageThatMerelySays200IsNotTheServerAgreeing() async throws {
        let wire = Wire()
        wire.agreement = Data("<html>Welcome to nginx</html>".utf8)
        let store = store(wire: wire, registered: false)
        store.didRegister(Data(repeating: 0xab, count: 32))
        await store.waitForSync()
        #expect(store.syncProblem != nil)
        #expect(await store.sendTest().contains("isn't registered"), "not taken for registered")

        wire.agreement = Data(#"{"ok":true,"pushes":false}"#.utf8)
        store.didRegister(Data(repeating: 0xab, count: 32))
        await store.waitForSync()
        #expect(store.syncProblem?.contains("push key") == true, "registered, but the server can't send yet")
    }

    @Test func aRefusalThatSaysWhyRemovesNothingOfThisPhones() async throws {
        let wire = Wire()
        wire.refusing["built.example.com"] = (409, #"{"error":"This invitation already has a phone.","code":"invitation_taken"}"#)
        let store = store(wire: wire)
        store.didRegister(Data(repeating: 0xcd, count: 32))
        await store.waitForSync()
        #expect(wire.requests.map(\.httpMethod) == ["PUT"], "the registration it has stays")
        #expect(store.syncProblem?.contains("already has a phone") == true)
    }

    @Test func tokensTheServerMayHoldAreAllTakenBackHoweverOftenTheTokenChanged() async throws {
        let wire = Wire(), permission = Permission(.authorized)
        let store = store(wire: wire, permission: permission)
        // Registered with "ab"; "cd" and then "ef" are sent, and neither answer comes back.
        wire.failing = ["built.example.com"]
        store.didRegister(Data(repeating: 0xcd, count: 32))
        await store.waitForSync()
        store.didRegister(Data(repeating: 0xef, count: 32))
        await store.waitForSync()
        wire.failing = []
        wire.requests = []
        permission.status = .denied
        await store.refreshPermission()
        await store.waitForSync()
        let removed = Set(wire.requests.filter { $0.httpMethod == "DELETE" }.map { String(($0.url?.lastPathComponent ?? "").prefix(2)) })
        #expect(removed == ["ab", "cd", "ef"])
        #expect(!wire.requests.contains { $0.httpMethod == "PUT" })
    }

    @Test func aRegistrationMadeWithAnotherServerIsNotThisOnesToHearAbout() async throws {
        let defaults = UserDefaults(suiteName: "AlertStoreTests.\(UUID().uuidString)")!
        let secrets = Secrets(), first = Wire()
        let before = store(secrets: secrets, wire: first, registered: false, builtIn: ("https://old.example.com", "old-token"), defaults: defaults)
        before.didRegister(Data(repeating: 0xab, count: 32))
        await before.waitForSync()
        #expect(first.to("old.example.com").map(\.httpMethod) == ["PUT"])
        // The next release names another built-in server, and notifications have been turned off.
        let second = Wire(), permission = Permission(.denied)
        let after = store(secrets: secrets, wire: second, builtIn: ("https://new.example.com", "new-token"), defaults: defaults, permission: permission)
        after.resume()
        await after.refreshPermission()
        await after.waitForSync()
        #expect(second.to("new.example.com").isEmpty, "the new server is never sent a token it wasn't given")
        // The old one is asked to forget the phone, with the invitation that was its own.
        #expect(second.to("old.example.com").map(\.httpMethod) == ["DELETE"])
        #expect(second.to("old.example.com").allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" })
    }

    @Test func onlyAnAnswerSettlesARemovalAndNeverAFailureToReach() async throws {
        let wire = Wire()
        wire.refusing["built.example.com"] = (401, #"{"error":"Not allowed"}"#)
        let store = store(wire: wire)
        let note = try await store.useServer(url: "https://mine.example.com", token: "mine-token")
        #expect(note != nil, "an invitation it no longer takes may be a mistake put right later")
        wire.refusing = [:]
        wire.failing = ["built.example.com"]
        store.resume()
        await store.waitForSync()
        wire.failing = []
        wire.refusing["built.example.com"] = (403, #"{"error":"This phone is registered by another install of Beeline"}"#)
        store.resume()
        await store.waitForSync()
        let asked = wire.to("built.example.com").count
        store.resume()
        await store.waitForSync()
        #expect(wire.to("built.example.com").count == asked, "another install's: nothing of this phone's is left there")
    }

    @Test func aTokenOnlyGoesToItsOwnAddress() async throws {
        let wire = Wire()
        let store = store(wire: wire)
        #expect(store.server?.isBuiltIn == true)
        let note = try await store.useServer(url: "https://mine.example.com", token: "mine-token")
        #expect(note == nil)
        await store.waitForSync()

        let old = wire.to("built.example.com"), new = wire.to("mine.example.com")
        #expect(old.map(\.httpMethod) == ["DELETE"], "the old server is only told to forget the phone")
        #expect(old.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer built-token" })
        #expect(new.contains { $0.httpMethod == "PUT" } && new.contains { $0.url?.path().hasSuffix("/v1/status") == true })
        #expect(new.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer mine-token" })
        let oldSecret = old.first?.value(forHTTPHeaderField: "X-Device-Secret")
        let newSecret = new.first { $0.httpMethod == "PUT" }?.value(forHTTPHeaderField: "X-Device-Secret")
        #expect(oldSecret != nil && newSecret != nil && oldSecret != newSecret, "each server its own secret")
    }

    @Test func oversizedLegacyWatchesStayLocalAndValidWatchesStillSync() async throws {
        var old = Self.validAlert()
        old.name = String(repeating: "😀", count: 61)
        let valid = Self.validAlert()
        let defaults = UserDefaults(suiteName: "PendingAlertTests.\(UUID().uuidString)")!
        defaults.set(try JSONEncoder().encode([old, valid]), forKey: "alerts")
        let wire = Wire(), store = store(wire: wire, defaults: defaults)
        #expect(store.delivery.pending[old.id] != nil)
        #expect(store.alerts == [old, valid])
        store.didRegister(Data(repeating: 0xab, count: 32))
        await store.waitForSync()
        await store.refreshStatus(force: true)
        struct Payload: Decodable { var alerts: [RouteAlert] }
        #expect(wire.requests.count == 2)
        for request in wire.requests {
            let body = try #require(request.httpBody)
            #expect(try JSONDecoder().decode(Payload.self, from: body).alerts.map(\.id) == [valid.id])
        }
        #expect(!store.save(old))
        old.name = String(repeating: "😀", count: 60)
        #expect(store.save(old))
        #expect(store.delivery.ready.map(\.id) == [old.id, valid.id])
        await store.waitForSync()
    }

    @Test func limitsApplyAcrossAFullCollectionAndToEditedDrafts() throws {
        let alerts = (0..<30).map { _ in Self.validAlert() }
        let defaults = UserDefaults(suiteName: "FullAlertTests.\(UUID().uuidString)")!
        defaults.set(try JSONEncoder().encode(alerts), forKey: "alerts")
        let store = store(defaults: defaults)
        #expect(!store.canAddWatch && !store.save(Self.validAlert()))
        var edit = alerts[0]
        #expect(store.saveProblem(for: edit) == nil)
        edit.windows = Array(repeating: edit.windows[0], count: 9)
        #expect(!store.save(edit))
        edit.windows.removeLast()
        edit.segments = Array(repeating: edit.segments[0], count: 9)
        #expect(!store.save(edit))
        edit.segments.removeLast()
        #expect(store.saveProblem(for: edit) == nil)
        #expect(store.alerts == alerts)
        let legacy = RouteAlert.Delivery(alerts + [Self.validAlert()])
        #expect(legacy.ready.count == 30 && legacy.pending.count == 1)
    }

    @Test func aFailedRemovalIsSaid() async throws {
        let wire = Wire()
        wire.failing = ["built.example.com"]
        let store = store(wire: wire)
        let note = try await store.useServer(url: "https://mine.example.com", token: "mine-token")
        #expect(note?.contains("built.example.com") == true)
        #expect(store.server?.url.host() == "mine.example.com")
    }

    @Test func launchRetriesAFormerServersRemovalWithItsOwnTokenEvenWhenAlertsAreOff() async throws {
        let secrets = Secrets(), offline = Wire()
        secrets.items[AlertStore.urlAccount] = "https://old.example.com"
        secrets.items[AlertStore.tokenAccount] = "old-token"
        offline.failing = ["old.example.com"]
        let defaults = UserDefaults(suiteName: "FormerServerTests.\(UUID().uuidString)")!
        let first = store(secrets: secrets, wire: offline, builtIn: nil, defaults: defaults)
        let note = try await first.useServer(url: "", token: "")
        #expect(note?.contains("old.example.com") == true)

        let wire = Wire()
        let next = store(secrets: secrets, wire: wire, builtIn: nil, defaults: defaults)
        #expect(next.server == nil)
        next.resume()
        await next.waitForSync()
        #expect(wire.requests.map(\.httpMethod) == ["DELETE"])
        #expect(wire.requests.first?.url?.host() == "old.example.com")
        #expect(wire.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
        #expect(wire.requests.first?.value(forHTTPHeaderField: "X-Device-Secret") == offline.requests.first?.value(forHTTPHeaderField: "X-Device-Secret"))
        next.resume()
        await next.waitForSync()
        #expect(wire.requests.count == 1, "a successful removal is forgotten")
    }

    @Test func reselectingAFormerServerCancelsItsPendingRemoval() async throws {
        let secrets = Secrets(), offline = Wire()
        secrets.items[AlertStore.urlAccount] = "https://old.example.com"
        secrets.items[AlertStore.tokenAccount] = "old-token"
        offline.failing = ["old.example.com"]
        let defaults = UserDefaults(suiteName: "ReselectedServerTests.\(UUID().uuidString)")!
        let first = store(secrets: secrets, wire: offline, builtIn: nil, defaults: defaults)
        try await first.useServer(url: "", token: "")
        let wire = Wire()
        let next = store(secrets: secrets, wire: wire, builtIn: nil, defaults: defaults)
        try await next.useServer(url: "https://old.example.com", token: "renewed-token")
        await next.waitForSync()
        #expect(wire.requests.contains { $0.httpMethod == "PUT" })
        #expect(!wire.requests.contains { $0.httpMethod == "DELETE" })
        #expect(wire.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-token" })
    }

    @Test func launchFinishesTheLastAlertRemovalAfterAnOfflineDelete() async throws {
        let secrets = Secrets(), offline = Wire()
        offline.failing = ["built.example.com"]
        let defaults = UserDefaults(suiteName: "LastAlertTests.\(UUID().uuidString)")!
        let first = store(secrets: secrets, wire: offline, defaults: defaults)
        let alert = try #require(first.alerts.first)
        first.delete(alert.id)
        await first.waitForSync()
        #expect(first.syncProblem != nil)
        let wire = Wire()
        let next = store(secrets: secrets, wire: wire, defaults: defaults)
        #expect(next.alerts.isEmpty)
        next.resume()
        await next.waitForSync()
        #expect(wire.requests.map(\.httpMethod) == ["DELETE"])
        #expect(wire.requests.first?.url?.lastPathComponent == Self.pushToken)
        next.resume()
        await next.waitForSync()
        #expect(wire.requests.count == 1)
    }

    @Test func aLockedKeychainMeansWaitNotAnotherServer() async {
        let secrets = Secrets(), wire = Wire()
        secrets.items[AlertStore.urlAccount] = "https://mine.example.com"
        secrets.items[AlertStore.tokenAccount] = "mine-token"
        secrets.locked = [AlertStore.urlAccount]
        let store = store(secrets: secrets, wire: wire)
        #expect(store.server == nil, "not the built-in server")
        await store.refreshStatus(force: true)
        #expect(wire.requests.isEmpty)

        secrets.locked = []
        await store.refreshStatus(force: true)
        #expect(wire.requests.map { $0.url?.host() } == ["mine.example.com"], "once readable, the entered server")
    }

    @Test func failedSettingsWriteKeepsTheOldPairAndRegistration() async throws {
        let secrets = Secrets(), wire = Wire()
        secrets.items[AlertStore.urlAccount] = "https://old.example.com"
        secrets.items[AlertStore.tokenAccount] = "old-token"
        let store = self.store(secrets: secrets, wire: wire)
        secrets.failingWrites = [AlertStore.choiceAccount]
        let draft = AlertServerDraft()
        draft.load(from: store)
        draft.url = "https://new.example.com"
        #expect(draft.token.isEmpty, "changing the server clears its prefilled token")
        draft.token = "new-token"
        #expect(!(await draft.apply(to: store)))
        #expect(draft.problem == AlertServer.Problem.cannotSave.message)
        #expect(wire.requests.isEmpty, "the old registration is only removed after the new pair is stored")
        #expect(store.enteredURL == "https://old.example.com")
        _ = await store.sendTest()
        #expect(wire.requests.map(\.httpMethod) == ["POST"], "the old registration still works")
        #expect(wire.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
        #expect(self.store(secrets: secrets).server == store.server, "relaunch restores the same complete pair")
    }

    @Test func resettingTheChoiceIgnoresLeftoverLegacyItems() async throws {
        let secrets = Secrets()
        secrets.items[AlertStore.urlAccount] = "https://old.example.com"
        secrets.items[AlertStore.tokenAccount] = "old-token"
        secrets.failingWrites = [AlertStore.urlAccount, AlertStore.tokenAccount]
        let store = self.store(secrets: secrets)
        try await store.useServer(url: "https://new.example.com", token: "new-token")
        await store.waitForSync()
        #expect(self.store(secrets: secrets).server?.token == "new-token")
        secrets.failingWrites.insert(AlertStore.choiceAccount)
        await #expect(throws: AlertServer.Problem.cannotSave) { try await store.useServer(url: "", token: "") }
        #expect(self.store(secrets: secrets).server?.token == "new-token", "a failed replacement keeps the previous record")
        secrets.failingWrites.remove(AlertStore.choiceAccount)
        try await store.useServer(url: "", token: "ignored")
        await store.waitForSync()
        #expect(self.store(secrets: secrets).server?.isBuiltIn == true)
        #expect(self.store(secrets: secrets, builtIn: nil).server == nil)
        secrets.locked = [AlertStore.choiceAccount]
        #expect(self.store(secrets: secrets).server == nil, "an unreadable choice never falls back to stale fields")
    }

    @Test func onlyTheConfiguredLegacyTenantInheritsItsSecret() async throws {
        let secrets = Secrets()
        let upper = AlertServer(url: try AlertServer.address("https://host.example/Team"), token: "upper", isBuiltIn: false)
        let lower = AlertServer(url: try AlertServer.address("https://host.example/team"), token: "lower", isBuiltIn: false)
        #expect(upper.legacyScopedAccount == lower.legacyScopedAccount)
        #expect(upper.secretAccount != lower.secretAccount)
        let legacy = String(repeating: "s", count: 43)
        secrets.items[AlertStore.urlAccount] = upper.url.absoluteString
        secrets.items[AlertStore.tokenAccount] = upper.token
        secrets.items[upper.legacyScopedAccount] = legacy
        let store = self.store(secrets: secrets, registered: false)
        try await store.useServer(url: lower.url.absoluteString, token: lower.token)
        await store.waitForSync()
        let relaunched = self.store(secrets: secrets)
        #expect(relaunched.server == lower)
        #expect(try relaunched.deviceSecret(for: lower) != legacy)
        #expect(try relaunched.deviceSecret(for: upper) == legacy)
    }

    @Test func randomFailureNeverRegistersWithPredictableBytes() async throws {
        let secrets = Secrets(), wire = Wire()
        var deps = AlertStore.Dependencies()
        deps.defaults = UserDefaults(suiteName: "AlertRandomTests.\(UUID().uuidString)")!
        deps.secrets = secrets
        deps.builtInURL = "https://built.example.com"
        deps.builtInToken = "built-token"
        deps.transport = { try await wire.send($0) }
        deps.fillRandomBytes = { _ in errSecNotAvailable }
        let store = AlertStore(deps)
        let server = try #require(store.server)
        await #expect(throws: AlertStore.AlertError.self) { try await store.send("PUT", path: "devices/test", to: server) }
        #expect(secrets.writes.isEmpty)
        #expect(wire.requests.isEmpty)
    }

    @Test func aLockedSecretIsNeverReplaced() throws {
        let secrets = Secrets()
        let store = store(secrets: secrets)
        let server = try #require(store.server)
        secrets.locked = [server.secretAccount]
        #expect(throws: AlertStore.AlertError.self) { try store.deviceSecret(for: server) }
        #expect(secrets.writes.isEmpty)
    }

    @Test func theBuiltInServersOldSecretCarriesOver() throws {
        let secrets = Secrets()
        let legacy = String(repeating: "s", count: 43)
        secrets.items[AlertServer.legacySecretAccount] = legacy
        let store = store(secrets: secrets)
        let builtIn = try #require(store.server)
        #expect(try store.deviceSecret(for: builtIn) == legacy, "phones registered by earlier builds stay theirs")
        let typed = AlertServer(url: builtIn.url, token: "built-token", isBuiltIn: false)
        #expect(try store.deviceSecret(for: typed) == legacy, "and entering the same address keeps it")
        #expect(secrets.items[AlertServer.legacySecretAccount] == legacy, "the old item stays for older builds")
        let other = AlertServer(url: URL(string: "https://other.example.com")!, token: "t", isBuiltIn: false)
        #expect(try store.deviceSecret(for: other) != legacy)
    }

    @Test func theOldSecretUnreadableMeansWait() throws {
        let secrets = Secrets()
        secrets.locked = [AlertServer.legacySecretAccount]
        let store = store(secrets: secrets)
        let builtIn = try #require(store.server)
        #expect(throws: AlertStore.AlertError.self) { try store.deviceSecret(for: builtIn) }
        #expect(secrets.writes.isEmpty, "no new secret minted over one that exists")
    }

    @Test func aSecretThatWontSaveIsNotUsed() throws {
        let secrets = Secrets()
        let store = store(secrets: secrets)
        let other = AlertServer(url: URL(string: "https://other.example.com")!, token: "t", isBuiltIn: false)
        secrets.failingWrites = [other.secretAccount]
        #expect(throws: AlertStore.AlertError.self) { try store.deviceSecret(for: other) }
    }

    @Test func theBuiltInAddressTypedDifferentlyIsTheSameServer() async throws {
        let wire = Wire(), secrets = Secrets()
        let legacy = String(repeating: "s", count: 43)
        secrets.items[AlertServer.legacySecretAccount] = legacy
        let store = store(secrets: secrets, wire: wire)
        try await store.useServer(url: " HTTPS://Built.Example.com:443/ ", token: "built-token")
        await store.waitForSync()
        #expect(!wire.requests.contains { $0.httpMethod == "DELETE" }, "not removed and re-registered")
        let server = try #require(store.server)
        #expect(server.url.absoluteString == "https://built.example.com")
        #expect(try store.deviceSecret(for: server) == legacy)
    }

    @Test func aFormerServerThatNoLongerKnowsThisPhoneIsNotAskedAgain() async throws {
        let wire = Wire()
        wire.refusing["built.example.com"] = (404, "Not found")
        let store = store(wire: wire)
        let note = try await store.useServer(url: "https://mine.example.com", token: "mine-token")
        #expect(note == nil, "nothing of this phone's is left there to remove")
        await store.waitForSync()
        store.resume()
        await store.waitForSync()
        #expect(wire.to("built.example.com").map(\.httpMethod) == ["DELETE"], "its credentials aren't sent there at every launch")
    }

    @Test func aReplyThatEchoesThisPhonesCredentialsIsNotShown() async throws {
        let wire = Wire()
        let store = store(wire: wire)
        let server = try #require(store.server)
        func said(_ body: String, path: String = "status") async throws -> String {
            wire.refusing["built.example.com"] = (400, body)
            do {
                try await store.send("POST", path: path, to: server)
            } catch AlertStore.AlertError.server(let message, let status) {
                #expect(status == 400)
                return message
            }
            Issue.record("the refusal should have thrown")
            return ""
        }
        #expect(try await said(#"{"error":"Try again in a minute"}"#) == "Try again in a minute")
        #expect(try await said(#"{"error":"bad header Authorization: Bearer built-token"}"#) == "The alert server said 400.")
        let secret = try store.deviceSecret(for: server)
        #expect(try await said(#"{"error":"x-device-secret was \#(secret)"}"#, path: "devices/\(Self.pushToken)/test") == "The alert server said 400.")
        #expect(try await said(#"{"error":"no device \#(Self.pushToken)"}"#, path: "devices/\(Self.pushToken)/test") == "The alert server said 400.")
    }

    @Test func anOversizedReplyIsRefused() async throws {
        let wire = Wire()
        wire.reply = Data(count: AlertStore.maxResponse + 1)
        let store = store(wire: wire)
        await #expect(throws: AlertStore.AlertError.self) { try await store.send("POST", path: "status", to: store.server!) }
    }

    @Test func noRedirects() async {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://built.example.com/v1/status")!)
        let response = HTTPURLResponse(url: URL(string: "https://built.example.com/v1/status")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://elsewhere.example.com/"])!
        let next = await NoRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                        newRequest: URLRequest(url: URL(string: "https://elsewhere.example.com/")!))
        #expect(next == nil)
    }

    @Test func serverTextIsKeptShort() throws {
        let long = String(repeating: "x", count: 10_000)
        let issues = (0..<40).map { _ in #"{"severity":"closed","title":"\#(long)","detail":"\#(long)"}"# }.joined(separator: ",")
        let json = #"{"checkedAt":"2026-11-24T12:00:00Z","alerts":[{"id":"a","issues":[\#(issues)],"upcoming":[]}]}"#
        let status = try AlertStatus.decode(Data(json.utf8))
        let entry = try #require(status.alerts.first)
        #expect(entry.issues.count == AlertStatus.maxIssues)
        #expect(entry.issues.allSatisfy { $0.title.count <= AlertStatus.maxTitle && $0.detail.count <= AlertStatus.maxDetail })
    }
}
