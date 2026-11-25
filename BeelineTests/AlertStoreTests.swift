import Foundation
import Security
import Testing
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
        var reply = Data(#"{"checkedAt":"2026-11-24T12:00:00Z","alerts":[]}"#.utf8)
        var code = 200
        /// Runs while a request is out, before its reply.
        var onSend: (() -> Void)?
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            onSend?()
            if failing.contains(request.url?.host() ?? "") { throw URLError(.cannotConnectToHost) }
            return (reply, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        func to(_ host: String) -> [URLRequest] { requests.filter { $0.url?.host() == host } }
    }

    static let pushToken = String(repeating: "ab", count: 32)

    static func validAlert() -> RouteAlert {
        var alert = RouteAlert()
        alert.segments = [.init(line: .init(id: "central", name: "Central"), mode: "tube")]
        return alert
    }

    /// The two watches `alert-status-partial.json` answers for.
    static func fixtureAlerts() -> [RouteAlert] {
        var elizabeth = validAlert(), district = validAlert()
        elizabeth.id = "6F1C2E1A-0B8E-4D59-9C3A-2E7A5D9B1C11"
        elizabeth.name = "Liverpool Street → Canary Wharf"
        district.id = "0D7A6C55-41C2-4E0B-8B3F-5A1E2C9D4F22"
        district.name = "District line"
        return [elizabeth, district]
    }

    static func defaults(with alerts: [RouteAlert]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "AlertStatusTests.\(UUID().uuidString)")!
        defaults.set(try! JSONEncoder().encode(alerts), forKey: "alerts")
        return defaults
    }

    /// Good service on `checked`; `unchecked` TfL couldn't be asked about.
    static func reply(checked: [RouteAlert], unchecked: [RouteAlert] = [], at date: Date = .now) -> Data {
        let entries = checked.map { #"{"id":"\#($0.id)","issues":[],"upcoming":[]}"# }.joined(separator: ",")
        let skipped = unchecked.map { "\"\($0.id)\"" }.joined(separator: ",")
        return Data(#"{"checkedAt":"\#(Time.isoString(date))","alerts":[\#(entries)],"unchecked":[\#(skipped)]}"#.utf8)
    }

    static let tflDown = Data(#"{"error":"TfL could not check every line. Try again later."}"#.utf8)

    func store(secrets: Secrets = Secrets(), wire: Wire = Wire(), registered: Bool = true,
               builtIn: (String, String)? = ("https://built.example.com", "built-token"),
               defaults existingDefaults: UserDefaults? = nil) -> AlertStore {
        let name = "AlertStoreTests.\(UUID().uuidString)"
        let defaults = existingDefaults ?? UserDefaults(suiteName: name)!
        if defaults.object(forKey: "alerts") == nil {
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
        deps.syncDelay = .zero
        return AlertStore(deps)
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

    @Test func anAlertIsCheckingUntilAskedAndWhileAskedAgain() async throws {
        let wire = Wire(), store = store(wire: wire)
        let id = try #require(store.alerts.first?.id)
        #expect(store.verdict(for: id) == .checking, "not asked yet")
        wire.code = 503
        wire.reply = Self.tflDown
        await store.refreshStatus(force: true)
        #expect(store.verdict(for: id) == .unavailable)
        var during: AlertStore.Verdict?
        wire.onSend = { during = store.verdict(for: id) }
        await store.refreshStatus(force: true)
        #expect(during == .checking)
        #expect(store.verdict(for: id) == .unavailable && !store.isChecking)
    }

    @Test func aPartialAnswerLeavesOutOnlyTheAlertTfLCouldntCheck() async throws {
        let wire = Wire(), alerts = Self.fixtureAlerts()
        wire.reply = try ProviderParsingTests.fixture("alert-status-partial")
        let store = store(wire: wire, defaults: Self.defaults(with: alerts))
        await store.refreshStatus(force: true)
        let checked = try #require(store.verdict(for: alerts[0].id).entry)
        #expect(checked.issues.map(\.level) == [.delays])
        #expect(checked.upcoming.isEmpty && checked.upcomingUnknown)
        #expect(store.verdict(for: alerts[1].id) == .unavailable)
        #expect(store.unchecked == [alerts[1].id])
        #expect(store.statusProblem == "TfL couldn't check District line just now. Try again later.")
        #expect(store.checkedAt == Time.iso("2026-11-25T08:14:03.512Z"))
    }

    @Test func aFailedCheckShowsNoOldVerdictUntilTheNextAnswer() async throws {
        let wire = Wire(), alerts = Self.fixtureAlerts()
        let store = store(wire: wire, defaults: Self.defaults(with: alerts))
        wire.reply = Self.reply(checked: alerts)
        await store.refreshStatus(force: true)
        let checkedAt = try #require(store.checkedAt)
        #expect(store.status.count == 2 && store.statusProblem == nil)

        wire.code = 503
        wire.reply = Self.tflDown
        await store.refreshStatus(force: true)
        let verdicts = alerts.map { store.verdict(for: $0.id) }
        #expect(verdicts == [.unavailable, .unavailable], "not the last answer's Good")
        #expect(store.statusProblem == "TfL could not check every line. Try again later.")
        #expect(store.checkedAt == checkedAt)

        wire.code = 200
        wire.reply = Self.reply(checked: alerts)
        await store.refreshStatus()
        #expect(wire.requests.count == 3, "a minute hasn't passed, but nothing has an answer")
        let entries = alerts.map { store.verdict(for: $0.id).entry }
        #expect(entries.allSatisfy { $0?.issues.isEmpty == true })
        #expect(store.unchecked.isEmpty && store.statusProblem == nil)
    }

    @Test func aRecentAnswerHoldsOffTheNextCheckOnlyOnceEveryAlertHasOne() async {
        let wire = Wire(), alerts = Self.fixtureAlerts()
        let store = store(wire: wire, defaults: Self.defaults(with: alerts))
        wire.reply = Self.reply(checked: [alerts[0]], unchecked: [alerts[1]])
        await store.refreshStatus(force: true)
        await store.refreshStatus()
        #expect(wire.requests.count == 2, "one still without an answer is asked about again")
        wire.reply = Self.reply(checked: alerts)
        await store.refreshStatus()
        await store.refreshStatus()
        #expect(wire.requests.count == 3)
        #expect(store.unchecked.isEmpty && store.statusProblem == nil)
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
        let ids = (0..<200).map { _ in "\"\(long)\"" }.joined(separator: ",")
        let json = #"{"checkedAt":"2026-11-24T12:00:00Z","alerts":[{"id":"a","issues":[\#(issues)],"upcoming":[]}],"unchecked":[\#(ids)]}"#
        let status = try AlertStatus.decode(Data(json.utf8))
        let entry = try #require(status.alerts.first)
        #expect(entry.issues.count == AlertStatus.maxIssues)
        #expect(entry.issues.allSatisfy { $0.title.count <= AlertStatus.maxTitle && $0.detail.count <= AlertStatus.maxDetail })
        #expect(status.unchecked.count == 64 && status.unchecked.allSatisfy { $0.count == 64 })
    }

    @Test func readsAPartialAnswer() throws {
        let status = try AlertStatus.decode(ProviderParsingTests.fixture("alert-status-partial"))
        let alerts = Self.fixtureAlerts()
        #expect(status.alerts.map(\.id) == [alerts[0].id])
        #expect(status.alerts[0].upcomingUnknown && status.alerts[0].upcoming.isEmpty)
        #expect(status.unchecked == [alerts[1].id])
        let older = try AlertStatus.decode(Data(#"{"checkedAt":"2026-11-24T12:00:00Z","alerts":[{"id":"a","issues":[],"upcoming":[]}]}"#.utf8))
        #expect(older.unchecked.isEmpty && !older.alerts[0].upcomingUnknown, "an older server's answer had everything checked")
    }
}
