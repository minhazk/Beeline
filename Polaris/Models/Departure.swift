import Foundation

/// One vehicle leaving a stop, as a departure board shows it.
struct Departure: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var line: String
    var mode: LegMode
    var lineColor: RGB?
    var headsign: String
    var stopName: String
    var stopCoordinate: Coordinate
    var scheduled: Date
    /// The live estimate where the feed has one, otherwise the timetable.
    var expected: Date
    var isRealtime: Bool
    var isCancelled: Bool
    var platform: String?
    /// When it reaches the stop the journey gets off at, if it calls there.
    var arrivalThere: Date?

    var delay: TimeInterval { expected.timeIntervalSince(scheduled) }
    var isLate: Bool { delay >= 60 }
}

/// A line's own status message, from the operator's feed ("Minor delays").
struct ServiceAlert: Identifiable, Hashable, Sendable {
    var header: String
    var detail: String?

    var id: String { header + (detail ?? "") }
}

/// A stop's departures around when a journey boards there, cut down to the ones
/// that also reach that journey's next stop off.
struct DepartureBoard: Hashable, Sendable {
    var stopName: String
    /// In order of when they leave.
    var departures: [Departure]
    /// The one the journey plans to catch, when the timetable has it.
    var plannedID: String?
    var alerts: [ServiceAlert] = []

    var planned: Departure? { departures.first { $0.id == plannedID } }

    private var running: [Departure] { departures.filter { !$0.isCancelled } }

    /// What missing the planned one costs: whatever leaves after it and gets
    /// there first (not just the next to leave, which may go the long way round).
    var nextAfterPlanned: Departure? {
        guard let planned else { return nil }
        return Self.soonestThere(running.filter { $0.expected > planned.expected })
    }

    /// Something leaving before the planned one that gets there sooner, worth
    /// running for if it hasn't gone.
    func earlierThanPlanned(after now: Date) -> Departure? {
        guard let planned else { return nil }
        let best = Self.soonestThere(running.filter { $0.expected < planned.expected && $0.expected > now })
        guard let best, let gain = arrivalDifference(best), gain < 0 else { return nil }
        return best
    }

    private static func soonestThere(_ departures: [Departure]) -> Departure? {
        departures.min { ($0.arrivalThere ?? $0.expected, $0.expected) < ($1.arrivalThere ?? $1.expected, $1.expected) }
    }

    /// How much later you'd reach the stop off on `other` than on the planned one.
    func arrivalDifference(_ other: Departure) -> TimeInterval? {
        guard let planned else { return nil }
        let mine = planned.arrivalThere ?? planned.expected
        return (other.arrivalThere ?? other.expected).timeIntervalSince(mine)
    }
}

/// Departures within a short walk: one row per line and direction, from its nearest stop.
struct NearbyLine: Identifiable, Hashable, Sendable {
    var line: String
    var mode: LegMode
    var lineColor: RGB?
    var headsign: String
    var stopName: String
    var stopCoordinate: Coordinate
    var distance: Double
    /// The next few, soonest first.
    var departures: [Departure]

    var id: String { "\(line)|\(headsign)" }

    func upcoming(at date: Date) -> NearbyLine? {
        var line = self
        line.departures = departures.filter { !$0.isCancelled && $0.expected >= date }
        return line.departures.isEmpty ? nil : line
    }
}
