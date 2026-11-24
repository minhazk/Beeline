import ActivityKit
import Foundation
import os

/// Where a trip's Live Activity goes: ActivityKit, or a test's record.
@MainActor protocol TripActivityDriving: AnyObject {
    /// Shows the trip. `adopt`: a trip picked up after Beeline was closed, whose Live Activity
    /// is still on the Lock Screen; carry on with that one rather than start a second.
    func start(destination: String, state: TripActivityAttributes.ContentState, adopt: Bool)
    func update(_ state: TripActivityAttributes.ContentState)
    func end()
}

/// Drives the trip's Live Activity. Countdowns run on the Lock Screen by
/// themselves; the app only updates it when the step changes.
@MainActor
final class TripActivity: TripActivityDriving {
    private var activity: Activity<TripActivityAttributes>?
    private var shown: TripActivityAttributes.ContentState?
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Beeline", category: "trip")

    func start(destination: String, state: TripActivityAttributes.ContentState, adopt: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        var leftovers = Activity<TripActivityAttributes>.activities
        if adopt, let index = leftovers.firstIndex(where: { [.active, .stale].contains($0.activityState) }) {
            // The one already showing: keep it, and push the trip as it is now (`shown` is nil).
            activity = leftovers.remove(at: index)
            Self.log.notice("Adopted Live Activity \(self.activity?.id ?? "", privacy: .public)")
        }
        // Any other is a trip left over from a crash or a force quit.
        for old in leftovers {
            nonisolated(unsafe) let old = old
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        if activity != nil {
            update(state)
            return
        }
        do {
            activity = try Activity.request(
                attributes: TripActivityAttributes(destination: destination),
                content: ActivityContent(state: state, staleDate: state.arrival.addingTimeInterval(30 * 60)))
        } catch {
            Self.log.error("Live Activity refused: \(String(describing: error), privacy: .public)")
        }
        shown = state
        Self.log.notice("Started Live Activity \(self.activity?.id ?? "none", privacy: .public)")
    }

    func update(_ state: TripActivityAttributes.ContentState) {
        guard let activity, state != shown else { return }
        shown = state
        // ActivityKit isn't marked Sendable, but its updates are safe from any thread.
        nonisolated(unsafe) let live = activity
        Task { await live.update(ActivityContent(state: state, staleDate: state.arrival.addingTimeInterval(30 * 60))) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        shown = nil
        nonisolated(unsafe) let live = activity
        Task { await live.end(nil, dismissalPolicy: .immediate) }
    }

    /// A launch with no trip to pick up: whatever Go left on the Lock Screen goes now, not
    /// when the next trip starts.
    static func endLeftovers() {
        for old in Activity<TripActivityAttributes>.activities {
            log.notice("Ended leftover Live Activity \(old.id, privacy: .public)")
            nonisolated(unsafe) let old = old
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
