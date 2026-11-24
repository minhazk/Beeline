import Foundation

enum ProviderID: String, CaseIterable, Codable, Hashable, Sendable {
    case google, tfl, transitous, apple

    var name: String {
        switch self {
        case .google: "Google"
        case .tfl: "TfL"
        case .transitous: "Transitous"
        case .apple: "Apple"
        }
    }

    /// Badge label on journey cards.
    var badge: String {
        switch self {
        case .google: "G"
        case .tfl: "TfL"
        case .transitous: "Tr"
        case .apple: "A"
        }
    }

    /// When two sources find the same journey, whose copy we keep (lower wins):
    /// TfL has London live running data, Google next, then the open timetable.
    var mergePriority: Int {
        switch self {
        case .tfl: 0
        case .google: 1
        case .transitous: 2
        case .apple: 3
        }
    }
}

/// Which provider found a journey, and with which of its query variants
/// ("Fewer changes", "Rail only", ...).
struct SourceTag: Codable, Hashable, Sendable {
    var provider: ProviderID
    var variant: String
}

enum LegMode: String, Codable, Sendable {
    case walk, bus, tube, rail, overground, elizabeth, dlr, tram, ferry, cableCar, coach, cycle, other

    var isTransit: Bool { self != .walk && self != .cycle }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .bus, .coach: "bus.fill"
        case .tube: "tram.fill.tunnel"
        case .rail, .overground, .elizabeth: "train.side.front.car"
        case .dlr, .tram: "tram.fill"
        case .ferry: "ferry.fill"
        case .cableCar: "cablecar.fill"
        case .cycle: "bicycle"
        case .other: "circle.fill"
        }
    }

    var label: String {
        switch self {
        case .walk: "Walk"
        case .bus: "Bus"
        case .tube: "Underground"
        case .rail: "Rail"
        case .overground: "Overground"
        case .elizabeth: "Elizabeth line"
        case .dlr: "DLR"
        case .tram: "Tram"
        case .ferry: "Boat"
        case .cableCar: "Cable car"
        case .coach: "Coach"
        case .cycle: "Cycle"
        case .other: "Transit"
        }
    }
}

/// sRGB colour from a provider's hex string, kept free of SwiftUI so models stay Sendable.
struct RGB: Codable, Hashable, Sendable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    /// Relative luminance, to pick legible text on a line pill.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

struct Leg: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var mode: LegMode
    /// "Northern", "25", "Thameslink". Nil for walking.
    var line: String?
    var lineColor: RGB?
    var headsign: String?
    var fromName: String
    var toName: String
    var departure: Date
    var arrival: Date
    var stopCount: Int?
    var distanceMeters: Double?
    var path: [Coordinate] = []
    var isRealtime = false
    /// Platform or stand at the boarding stop, where the source knows it.
    var platform: String?
    /// Stops called at between boarding and alighting, in order.
    var intermediateStops: [String] = []

    var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    /// "platform 2", or for a bus "stop G" (TfL letters its stops), lower case for mid-sentence.
    /// A no-break space keeps the word and its number on one line.
    func standing(at platform: String) -> String {
        [.bus, .coach].contains(mode) ? "stop\u{00A0}\(platform)" : "platform\u{00A0}\(platform)"
    }
    /// Where the leg starts and ends, from its drawn path.
    var start: Coordinate? { path.first }
    var end: Coordinate? { path.last }
}

struct Journey: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var departure: Date
    var arrival: Date
    var legs: [Leg]
    var sources: [SourceTag]
    /// e.g. "£2.80", when the source could price every leg.
    var fare: String?
    var hasDisruption = false
    /// What TfL reports about the lines and stations this journey uses.
    var notices: [ServiceNotice] = []

    /// A reported closure means this journey probably won't work as planned.
    var isBlocked: Bool { notices.contains { $0.severity == .closed } }
    var worstNotice: ServiceNotice? { notices.max { $0.severity < $1.severity } }

    var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    var transitLegs: [Leg] { legs.filter(\.mode.isTransit) }
    var changes: Int { max(0, transitLegs.count - 1) }
    var walkingTime: TimeInterval { legs.filter { $0.mode == .walk }.reduce(0) { $0 + $1.duration } }
    var isRealtime: Bool { legs.contains(where: \.isRealtime) }
    var providers: [ProviderID] {
        var seen: [ProviderID] = []
        for tag in sources where !seen.contains(tag.provider) { seen.append(tag.provider) }
        return seen
    }

    /// Same sequence of lines = same journey, whichever source found it.
    var routeSignature: String {
        let parts = transitLegs.map { leg in "\(leg.mode.family):\(Journey.normalise(leg.line ?? leg.mode.rawValue))" }
        return parts.isEmpty ? "walk" : parts.joined(separator: ">")
    }

    /// First boarding time, used to tell apart the same route on different departures.
    var firstBoarding: Date { transitLegs.first?.departure ?? departure }

    static func normalise(_ line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: " line", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension LegMode {
    /// Coarse grouping for matching across sources, which disagree on whether the
    /// Elizabeth line is "rail" or "subway" and the Overground "rail" or "overground".
    var family: String {
        switch self {
        case .rail, .overground, .elizabeth, .tube, .dlr, .tram: "rail"
        case .bus, .coach: "road"
        default: rawValue
        }
    }
}

/// Something reported wrong on the network that touches one leg of a journey.
struct ServiceNotice: Codable, Hashable, Sendable {
    enum Severity: Int, Codable, Comparable, Sendable {
        /// Worth knowing.
        case minor
        /// Expect it to take longer.
        case delays
        /// The journey probably won't work as planned.
        case closed

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// The same operator notice can apply to several legs or alternatives.
    struct DisplayID: Hashable {
        let title: String
        let detail: String
        let severity: Severity
        let source: ProviderID
    }
    var displayID: DisplayID { DisplayID(title: title, detail: detail, severity: severity, source: source) }

    /// "Canary Wharf part closed (Elizabeth line)", "Minor delays on the Jubilee".
    var title: String
    /// The operator's own words.
    var detail: String
    var severity: Severity
    var source: ProviderID
    var leg: UUID
}

/// Apple only estimates transit journeys (MapKit returns no route for `.transit`),
/// so it's a reference time rather than a journey.
struct AppleEstimate: Hashable, Sendable {
    var travelTime: TimeInterval
    var departure: Date
    var arrival: Date
}
