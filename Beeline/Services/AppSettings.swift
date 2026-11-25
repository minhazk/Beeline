import Foundation
import Observation
import Security
import UIKit

@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var disabledProviders: Set<ProviderID> {
        didSet { defaults.set(disabledProviders.map(\.rawValue), forKey: "disabledProviders") }
    }

    /// Query each source several ways (fewer changes, less walking, mode filters).
    var deepSearch: Bool {
        didSet { defaults.set(deepSearch, forKey: "deepSearch") }
    }

    /// Results order and filters stick between searches.
    var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") }
    }

    var routeFilter: RouteFilter {
        didSet { defaults.set(try? JSONEncoder().encode(routeFilter), forKey: "routeFilter") }
    }

    /// Keys pasted in Settings live in the Keychain and beat the build-time ones.
    /// Written only when changed here, never while being read in (`loading`).
    var googleKeyOverride: String { didSet { if !loading { Keychain.set(googleKeyOverride, for: "google") } } }
    var tflKeyOverride: String { didSet { if !loading { Keychain.set(tflKeyOverride, for: "tfl") } } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledProviders = Set((defaults.stringArray(forKey: "disabledProviders") ?? []).compactMap(ProviderID.init))
        deepSearch = defaults.object(forKey: "deepSearch") as? Bool ?? true
        sortOrder = defaults.string(forKey: "sortOrder").flatMap(SortOrder.init) ?? .best
        routeFilter = defaults.data(forKey: "routeFilter").flatMap { try? JSONDecoder().decode(RouteFilter.self, from: $0) } ?? RouteFilter()
        googleKeyOverride = ""
        tflKeyOverride = ""
        loadKeys()
        // A launch in the background before the first unlock can't read them yet: again once it can.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadKeys() }
        }
    }

    /// Keys the Keychain couldn't give yet (locked since the phone started): read again before use.
    private(set) var keysPending = false
    private var loading = false

    /// Reads the entered keys. An unreadable one leaves its value as it was and is tried again;
    /// nothing is written back while loading.
    private func loadKeys() {
        loading = true
        defer { loading = false }
        var pending = false
        for (account, apply) in [("google", { (v: String) in self.googleKeyOverride = v }),
                                 ("tfl", { (v: String) in self.tflKeyOverride = v })] {
            switch Keychain.read(account) {
            case .value(let v): apply(v)
            case .notFound: apply("")
            case .unreadable: pending = true
            }
        }
        keysPending = pending
    }

    var googleKey: String? {
        if keysPending { loadKeys() }
        return Self.firstNonEmpty(googleKeyOverride, Bundle.main.object(forInfoDictionaryKey: "GoogleRoutesAPIKey") as? String)
    }
    var tflKey: String? {
        if keysPending { loadKeys() }
        return Self.firstNonEmpty(tflKeyOverride, Bundle.main.object(forInfoDictionaryKey: "TfLAppKey") as? String)
    }
    var hasBuiltInGoogleKey: Bool { Self.firstNonEmpty(Bundle.main.object(forInfoDictionaryKey: "GoogleRoutesAPIKey") as? String) != nil }
    var hasBuiltInTfLKey: Bool { Self.firstNonEmpty(Bundle.main.object(forInfoDictionaryKey: "TfLAppKey") as? String) != nil }

    func isEnabled(_ provider: ProviderID) -> Bool { !disabledProviders.contains(provider) }

    func setEnabled(_ provider: ProviderID, _ enabled: Bool) {
        if enabled { disabledProviders.remove(provider) } else { disabledProviders.insert(provider) }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

/// A contact for the User-Agent: an email address or a web address, short and on one line.
enum Contact {
    static func valid(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200, !text.contains(where: { $0.isNewline || $0 == "(" || $0 == ")" }) else { return nil }
        if text.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil { return text }
        if let parts = URLComponents(string: text), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
           let host = parts.host, host.contains(".") { return text }
        return nil
    }
}

/// What a Keychain read found. "Unreadable" (the phone locked since it started, say) is not
/// "not there": callers wait rather than fall back to something else or make a new value.
enum KeychainRead: Equatable, Sendable {
    case value(String), notFound, unreadable

    var value: String? { if case .value(let v) = self { v } else { nil } }
}

/// Where values live: the Keychain, or a test's own store.
protocol SecretStore: Sendable {
    func read(_ account: String) -> KeychainRead
    /// False when it couldn't be kept: a value that wasn't saved mustn't be used.
    @discardableResult func write(_ value: String, for account: String) -> Bool
}

struct SystemKeychain: SecretStore {
    func read(_ account: String) -> KeychainRead { Keychain.read(account) }
    @discardableResult func write(_ value: String, for account: String) -> Bool { Keychain.set(value, for: account) }
}

enum Keychain {
    /// The bundle ID and ".keys": what every earlier build used, so keys already saved stay.
    static let service = "\(Bundle.main.bundleIdentifier ?? "beeline").keys"
    /// Readable after the first unlock since the phone started, so a launch in the background
    /// (Go's location updates) can read the alerts server while the phone is locked.
    private static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlock }

    static func get(_ account: String) -> String? { read(account).value }

    static func read(_ account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return mapped(status, result as? Data)
    }

    /// What a read's status means. Anything but found or not found (the phone locked since it
    /// started is errSecInteractionNotAllowed) is "unreadable": wait, don't assume it's absent.
    static func mapped(_ status: OSStatus, _ data: Data?) -> KeychainRead {
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8) else { return .unreadable }
            return .value(text)
        case errSecItemNotFound: return .notFound
        default: return .unreadable
        }
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            let deleted = SecItemDelete(query as CFDictionary)
            return deleted == errSecSuccess || deleted == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: accessible]
        switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            let item = query.merging(attributes) { _, new in new }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        default: return false
        }
    }

    /// Items saved by earlier builds had the default (readable only while unlocked): moved to
    /// after-first-unlock in place, values untouched. Once it has worked it isn't tried again.
    static func migrateAccessibility(defaults: UserDefaults = .standard, service: String = Keychain.service) {
        let done = "keychain.afterFirstUnlock"
        guard !defaults.bool(forKey: done) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { defaults.set(true, forKey: done) }
    }
}
