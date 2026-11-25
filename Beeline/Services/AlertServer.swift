import CryptoKit
import Foundation

/// Where alerts are kept and checked (worker/): an address and the token that server expects.
/// The one built in at build time, or one entered in Settings. They go as a pair: a token is
/// only ever sent to the address it was given with.
struct AlertServer: Codable, Equatable, Sendable {
    var url: URL
    var token: String
    /// Built in from Config/*.xcconfig rather than entered in Settings.
    var isBuiltIn: Bool

    enum Problem: Error, Equatable {
        case notAnAddress, notHTTPS, hasCredentials, noToken, keychainLocked, cannotSave, changeInProgress

        var message: String {
            switch self {
            case .notAnAddress: "That isn't a web address."
            case .notHTTPS: "The address must start with https:// (http only for localhost, while developing)."
            case .hasCredentials: "Put the token in its own field, not in the address."
            case .noToken: "Enter this phone's invitation for the alert server."
            case .keychainLocked: "The phone's Keychain can't be read until it's unlocked. Try again."
            case .cannotSave: "Couldn't save the server settings in the Keychain. Your previous settings are still in use."
            case .changeInProgress: "A server change is already in progress. Try again when it finishes."
            }
        }
    }

    /// An address someone typed or built in: https, or http for a server on this Mac during
    /// development. No user, password, query or fragment; a trailing slash is dropped.
    static func address(_ text: String) throws(Problem) -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.query == nil, parts.fragment == nil else { throw .notAnAddress }
        if parts.user != nil || parts.password != nil { throw .hasCredentials }
        switch scheme {
        case "https": break
        case "http" where allowsLocalHTTP && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host): break
        case "http": throw .notHTTPS
        default: throw .notAnAddress
        }
        parts.scheme = scheme
        parts.host = host
        // One spelling per server: the default port is dropped; the path is kept exactly (paths
        // are case-sensitive), less any trailing slash.
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        guard let url = parts.url else { throw .notAnAddress }
        return url
    }

    /// Plain http reaches only a server on the same machine. On a phone that is the phone itself,
    /// where whatever listens would be handed the invitation, the device secret and the push
    /// token: so only in development builds and the simulator, where it is the Mac.
    static var allowsLocalHTTP: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// The server to use: one entered in Settings when there is one, else the built-in one.
    /// Nil (alerts off) when neither is complete, or the built-in address doesn't pass.
    static func resolve(enteredURL: String, enteredToken: String, builtInURL: String?, builtInToken: String?) -> AlertServer? {
        let trim = { (s: String?) in s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if !trim(enteredURL).isEmpty {
            guard let url = try? address(enteredURL), !trim(enteredToken).isEmpty else { return nil }
            return AlertServer(url: url, token: trim(enteredToken), isBuiltIn: false)
        }
        guard let url = try? address(trim(builtInURL)), !trim(builtInToken).isEmpty else { return nil }
        return AlertServer(url: url, token: trim(builtInToken), isBuiltIn: true)
    }

    /// The Keychain account of this install's device secret for this server: by its address
    /// alone, so a server can't use the secret it was sent against another, and the same
    /// server keeps its secret whether it is built in or entered. (Earlier builds kept the
    /// built-in server's under `legacySecretAccount`; AlertStore carries that over.)
    var secretAccount: String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "alerts.secret.v2." + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Older builds folded the URL path to lowercase too. Only the server configured on
    /// upgrade may inherit this value; selecting a new server must never claim it.
    var legacyScopedAccount: String {
        let digest = SHA256.hash(data: Data(url.absoluteString.lowercased().utf8))
        return "alerts.secret." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static let legacySecretAccount = "alerts.secret"

    /// For Settings: the host, with a port or path when it has one.
    var label: String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = nil
        return (parts?.string ?? url.absoluteString).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
