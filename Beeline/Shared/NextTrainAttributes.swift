import ActivityKit
import Foundation

/// The next few trains from one station, on the Lock Screen and in the Dynamic Island. Started
/// from a line near you, a departure board, a journey, or by the alerts server at a saved line's
/// travel times; kept up to date by that server's pushes (worker/src/activities.ts), which write
/// this same JSON: `BeelineTests/Fixtures/next-train-contract.json`. So times are seconds since
/// 1970, not `Date`s. Compiled into both the app and the widget extension.
struct NextTrainAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Soonest first. The Lock Screen shows the first three still to leave.
        var trains: [Train]
        /// Trouble on the way, in a few words: "Severe delays".
        var notice: String?
        /// When these times were worked out, seconds since 1970.
        var updated: Double
        /// Live estimates (TfL's), rather than the timetable.
        var live: Bool

        struct Train: Codable, Hashable {
            /// When it leaves, seconds since 1970.
            var at: Double
            var cancelled: Bool
            /// Minutes behind the timetable, when it's at least one.
            var late: Int?

            var date: Date { Date(timeIntervalSince1970: at) }
        }

        /// The trains still to leave at `now` (one leaving this moment counts), soonest first.
        func upcoming(at now: Date, count: Int = 3) -> [Train] {
            Array(trains.filter { $0.at >= now.timeIntervalSince1970 - 15 }.prefix(count))
        }

        /// When the phone should look again without a push: just after the first train leaves.
        func staleDate(after now: Date) -> Date {
            let first = trains.first { $0.at > now.timeIntervalSince1970 }
            return min(first.map { $0.date.addingTimeInterval(30) } ?? now.addingTimeInterval(600), now.addingTimeInterval(15 * 60))
        }
    }

    /// What the alerts server follows: TfL's line, and its ids for where you board and get off.
    struct Follow: Codable, Hashable, Sendable {
        struct Line: Codable, Hashable, Sendable { var id: String; var name: String }
        struct Station: Codable, Hashable, Sendable { var id: String; var name: String }
        var line: Line
        /// TfL's mode: tube, dlr, elizabeth-line, overground, tram.
        var mode: String
        var from: Station
        var to: Station
    }

    /// What started it, so the same thing isn't followed twice: "alert:…", "line:…", "leg:…".
    var key: String
    /// As the line's pill says it: "Central", "Elizabeth", "Mildmay".
    var line: String
    /// SF Symbol for the mode.
    var symbol: String
    /// Hex, so the extension needn't know the app's line colours.
    var color: String?
    /// Where you board: "Redbridge".
    var stop: String
    /// Where you're going, or where the trains are heading: "Liverpool Street".
    var towards: String?
    /// For the server to keep it up to date; nil when only the timetable has it (outside TfL).
    var follow: Follow?
    /// When it goes, seconds since 1970.
    var ends: Double
}
