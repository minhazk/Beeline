import Foundation

/// The setup step a new install sees once: what works with nothing set, and the optional keys.
/// Never for an install that has been used (keys, saved places, alerts, settings or Google
/// counts already stored), so phones updating from earlier builds go straight to the map.
enum FirstRun {
    static let seenKey = "setup.seen"

    /// What an install has stored already.
    struct Facts: Equatable {
        var seen = false
        /// The Keychain couldn't be read (locked since the phone started): decide another launch.
        var undecided = false
        /// Keys, an alerts server or a contact entered in Settings.
        var hasEnteredValues = false
        /// Anything an earlier launch wrote: places, alerts, settings, Google's count.
        var hasPriorData = false
    }

    static func shouldShow(_ facts: Facts) -> Bool {
        !facts.seen && !facts.undecided && !facts.hasEnteredValues && !facts.hasPriorData
    }

    /// UserDefaults keys only an install that has been used has.
    static let priorUseKeys = [
        "places.home", "places.work", "places.recents", "alerts", "alerts.registered", "alerts.token",
        "googleAllowance", "disabledProviders", "deepSearch", "sortOrder", "routeFilter", "appearance", "wholeMap",
    ]
    static let keychainAccounts = ["google", "tfl", "contact", "alerts.server.choice", "alerts.server.url"]

    static func facts(defaults: UserDefaults = .standard, keychain: (String) -> KeychainRead = Keychain.read) -> Facts {
        let reads = keychainAccounts.map(keychain)
        return Facts(
            seen: defaults.bool(forKey: seenKey),
            undecided: reads.contains(.unreadable),
            hasEnteredValues: reads.contains { !($0.value ?? "").isEmpty },
            hasPriorData: priorUseKeys.contains { defaults.object(forKey: $0) != nil })
    }

    /// Decides at launch, once: shows it, or never will. Either way it isn't asked again, unless
    /// the Keychain couldn't be read, when nothing is decided or written and a later launch asks.
    @MainActor static func takeTurn(defaults: UserDefaults = .standard, keychain: (String) -> KeychainRead = Keychain.read) -> Bool {
        let facts = facts(defaults: defaults, keychain: keychain)
        guard !facts.undecided || facts.seen || facts.hasPriorData else { return false }
        defaults.set(true, forKey: seenKey)
        return shouldShow(facts)
    }
}
