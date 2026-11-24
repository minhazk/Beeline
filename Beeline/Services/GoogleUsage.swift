import Foundation
import Network
import Observation

/// The month's Google Routes requests, kept on this phone. Every search and re-plan spends
/// from it before it sends, and stops asking Google as the free allowance runs out.
@MainActor @Observable
final class GoogleUsage {
    static let shared = GoogleUsage()

    private let defaults: UserDefaults
    private static let key = "googleAllowance"
    private(set) var allowance: GoogleAllowance

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowance = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(GoogleAllowance.self, from: $0) } ?? GoogleAllowance()
    }

    func spend(_ requests: Int, now: Date = .now) {
        guard requests > 0 else { return }
        allowance.spend(requests, now: now)
        defaults.set(try? JSONEncoder().encode(allowance), forKey: Self.key)
    }
}

/// Whether the phone has a way to the internet at all. A re-plan isn't sent without one
/// (deep underground): it waits for the next stop instead.
@MainActor @Observable
final class NetworkPath {
    static let shared = NetworkPath()
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkPath.shared.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "beeline.network-path"))
    }
}
