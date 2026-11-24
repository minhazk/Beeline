import ActivityKit
import Foundation

/// The trip on the Lock Screen and in the Dynamic Island. Compiled into both the
/// app and the widget extension; keep it to plain values (under 4 KB in all).
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// SF Symbol for what you're doing now.
        var symbol: String
        /// "Walk to King's Cross St. Pancras", "Northern to Bank".
        var title: String
        /// "Northern line from platform 8", "4 stops".
        var detail: String
        var lineName: String?
        /// Hex, so the extension needn't know the app's line colours.
        var lineColor: String?
        /// "Leaves", "Get off", "Arrive".
        var countdownLabel: String
        var countdownTo: Date
        var arrival: Date
        var step: Int
        var stepCount: Int
        /// If you miss the ride you're heading for: when the next one leaves (its
        /// line when it isn't yours), how many minutes later that gets you to the
        /// end (at least, when `missCostIsFloor`), and the later change it costs you
        /// ("11:52 GWR") or the next one you'd still make.
        var nextDeparture: Date?
        var nextLine: String?
        var missCost: Int?
        var missCostIsFloor = false
        var connection: String?
        var losesConnection = false

        /// Under the countdown: "+20 min", "no later".
        var missCostText: String? {
            guard nextDeparture != nil, let missCost else { return nil }
            if missCostIsFloor { return "\(max(missCost, 1))+ min" }
            if missCost == 0 { return "no later" }
            return missCost > 0 ? "+\(missCost) min" : "\(-missCost) min sooner"
        }

        /// Worth running for: it costs you a change, or a lot of time.
        var missIsCostly: Bool { losesConnection || missCostIsFloor || (missCost ?? 0) >= 10 }

        /// "Next 11:38, misses the 11:52 GWR".
        var missDetail: String? {
            guard let nextDeparture else { return nil }
            let next = "Next " + (nextLine.map { "\($0) " } ?? "") + Self.clock(nextDeparture)
            guard let connection else { return next }
            return next + (losesConnection ? ", misses the \(connection)" : ", still makes the \(connection)")
        }

        static func clock(_ date: Date) -> String {
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
    }

    var destination: String
}
