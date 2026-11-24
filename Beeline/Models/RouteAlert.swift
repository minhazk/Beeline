import Foundation

/// A stretch of line you use regularly, and when you travel. Beeline's server
/// (`worker/`) checks TfL every two minutes during those times and sends a
/// notification when something on that stretch closes or is delayed, and the
/// evening before for planned works. The JSON is the server's contract:
/// `BeelineTests/Fixtures/alert-contract.json`.
struct RouteAlert: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString
    /// Empty means `defaultName`.
    var name = ""
    /// ISO weekdays: 1 is Monday.
    var days: [Int] = Array(1...5)
    var windows: [TimeWindow] = [TimeWindow(start: 7 * 60, end: 10 * 60), TimeWindow(start: 16 * 60 + 30, end: 19 * 60 + 30)]
    var minorDelays = true
    var segments: [Segment] = []
    /// Which way you ride. Nil, as alerts saved before this are, is both ways; the server reads
    /// a missing one the same. Only trouble TfL reports one way only depends on it.
    var direction: Direction?

    enum Direction: String, Codable, CaseIterable, Sendable {
        /// From the first stretch's `from` to the last one's `to`.
        case out
        case back
        case both

        /// A word a newer build saved is both ways, so the alerts still load.
        init(from decoder: any Decoder) throws {
            self = Direction(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .both
        }
    }

    var way: Direction {
        get { direction ?? .both }
        set { direction = newValue }
    }

    /// Where the alert starts and ends, when it's a stretch rather than whole lines.
    var ends: (from: String, to: String)? {
        guard let from = segments.first?.from?.name, let to = segments.last?.to?.name, from != to else { return nil }
        return (from, to)
    }

    /// "Both ways", "To Canary Wharf", "To Liverpool Street".
    func label(_ direction: Direction) -> String {
        switch (direction, ends) {
        case (.out, let ends?): "To \(ends.to)"
        case (.back, let ends?): "To \(ends.from)"
        default: "Both ways"
        }
    }

    struct Line: Codable, Hashable, Sendable {
        /// TfL's line id ("elizabeth").
        var id: String
        /// As people say it ("Elizabeth line", "District line", "Southeastern").
        var name: String
    }

    struct Station: Codable, Hashable, Sendable {
        /// TfL's ids for it, "|" between: "910GLIVSTLL|910GLIVST".
        var id: String
        var name: String
    }

    struct Segment: Codable, Hashable, Sendable, Identifiable {
        var line: Line
        /// TfL's mode name: tube, dlr, elizabeth-line, overground, tram, national-rail.
        var mode: String
        /// Nil for the whole line.
        var from: Station?
        var to: Station?
        /// From `from` to `to`, in order; empty for the whole line.
        var stations: [String] = []

        var id: String { "\(line.id)|\(from?.id ?? "")|\(to?.id ?? "")" }
        var legMode: LegMode { NetworkStatus.mode(mode)?.refined(line: line.name, agency: nil) ?? .rail }
        var color: RGB? { LineColors.color(line: line.name, mode: legMode) }
        var stretch: String {
            guard let from, let to else { return "Whole line" }
            return "\(from.name) to \(to.name)"
        }
    }

    struct TimeWindow: Codable, Hashable, Sendable {
        /// Minutes after midnight.
        var start: Int
        var end: Int
        /// This time's own way ("to Paddington" mornings, "to Reading" evenings), kept as chosen even
        /// when it matches the alert's. Nil, as every time saved before this is, follows the alert's
        /// `direction`; it isn't written out.
        var direction: Direction?
    }

    /// The way a time is ridden: its own, else the alert's.
    func way(of window: TimeWindow) -> Direction { window.direction ?? way }

    /// Times that go different ways, on a stretch with ends: then names and times say each one's way.
    var waysDiffer: Bool { ends != nil && Set(windows.map(way(of:))).count > 1 }

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name }

    /// "Liverpool Street → Canary Wharf" (the other way round coming back), or the line for a
    /// whole-line alert.
    var defaultName: String {
        guard !segments.isEmpty else { return "New alert" }
        if let ends {
            if waysDiffer { return "\(ends.from) ⇄ \(ends.to)" }
            let scheduledWay = windows.first.map(way(of:)) ?? way
            return scheduledWay == .back ? "\(ends.to) → \(ends.from)" : "\(ends.from) → \(ends.to)"
        }
        return segments.map(\.line.name).uniqued().formatted(.list(type: .and))
    }

    /// "Weekdays, 07:00–10:00 and 16:30–19:30", or with times going different ways,
    /// "Weekdays, 07:00–10:00 to Canary Wharf and 16:30–19:30 to Liverpool Street".
    var whenText: String {
        let differ = waysDiffer
        let times = windows.map { window in
            let time = "\(Self.clock(window.start))–\(Self.clock(window.end))"
            guard differ else { return time }
            let label = label(way(of: window))
            return "\(time) \(label.prefix(1).lowercased() + label.dropFirst())"
        }.formatted(.list(type: .and))
        return times.isEmpty ? daysText : "\(daysText), \(times)"
    }

    var daysText: String {
        switch Set(days) {
        case Set(1...5): "Weekdays"
        case Set(1...7): "Every day"
        case [6, 7]: "Weekends"
        default:
            days.filter { (1...7).contains($0) }.sorted().map { Calendar.current.shortWeekdaySymbols[$0 % 7] }.formatted(.list(type: .and))
        }
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// A body the server takes (`PUT /v1/devices/:token`).
    struct Registration: Encodable {
        var environment: String
        var timeZone: String
        var alerts: [Wire]
    }

    /// What's sent: the name is always filled in, so the notification says it.
    struct Wire: Encodable {
        var alert: RouteAlert

        func encode(to encoder: any Encoder) throws {
            var copy = alert
            copy.name = alert.displayName
            try copy.encode(to: encoder)
        }
    }

    static let maxAlerts = 30, maxSegments = 8, maxWindows = 8, maxName = 120

    /// The Worker measures strings in UTF-16 units. Keep the local draft intact so it can be corrected.
    var deliveryProblem: String? {
        func identifier(_ text: String) -> Bool {
            text.utf16.count <= 64 && text.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil && text.contains { $0 != "." }
        }
        func stationID(_ text: String) -> Bool {
            text.utf16.count <= 200 && text.wholeMatch(of: /[A-Za-z0-9._-]+(\|[A-Za-z0-9._-]+)*/) != nil
        }
        func station(_ station: Station) -> Bool {
            stationID(station.id) && !station.name.isEmpty && station.name.utf16.count <= 120
        }
        guard identifier(id) else { return "Recreate this watch to replace its invalid identifier." }
        guard displayName.utf16.count <= Self.maxName else { return "Use a shorter name (up to 120 characters; some symbols count twice)." }
        guard (1...Self.maxSegments).contains(segments.count) else { return "Choose between 1 and 8 line sections." }
        guard (1...Self.maxWindows).contains(windows.count) else { return "Choose between 1 and 8 travel times." }
        guard (1...7).contains(days.count), days.allSatisfy({ (1...7).contains($0) }) else { return "Choose your travel days." }
        guard windows.allSatisfy({ (0..<1440).contains($0.start) && (0..<1440).contains($0.end) && $0.start != $0.end }) else {
            return "Give each travel time a different start and end."
        }
        for part in segments {
            guard identifier(part.line.id), !part.line.name.isEmpty, part.line.name.utf16.count <= 80,
                  NetworkStatus.mode(part.mode) != nil, part.from.map(station) != false, part.to.map(station) != false,
                  part.stations.count <= 200, part.stations.allSatisfy(stationID) else { return "Remove and reselect the affected line section." }
        }
        return nil
    }

    /// Select complete watches in saved order. Older oversized watches stay on the phone for editing.
    struct Delivery {
        private(set) var ready: [RouteAlert] = []
        private(set) var pending: [String: String] = [:]
        private var lines = Set<String>()
        private var bytes: Int

        init(_ alerts: [RouteAlert]) {
            let envelope = Registration(environment: "production", timeZone: TimeZone.current.identifier, alerts: [])
            bytes = (try? JSONEncoder().encode(envelope).count) ?? 256
            for alert in alerts {
                if let problem = include(alert) { pending[alert.id] = problem }
            }
        }

        mutating func include(_ alert: RouteAlert) -> String? {
            if let problem = alert.deliveryProblem { return problem }
            guard ready.count < RouteAlert.maxAlerts else { return "You can watch up to 30 routes. Remove another watch to make room." }
            let updatedLines = lines.union(alert.segments.map(\.line.id))
            guard updatedLines.count <= 48 else { return "Your watches can cover up to 48 different lines. Remove a line to make room." }
            guard let size = try? JSONEncoder().encode(Wire(alert: alert)).count,
                  bytes + size + (ready.isEmpty ? 0 : 1) <= 256 * 1024 else { return "Shorten a line section or remove a watch to fit the server's size limit." }
            bytes += size + (ready.isEmpty ? 0 : 1)
            lines = updatedLines
            ready.append(alert)
            return nil
        }
    }
}

/// What the server says about each alert: trouble now, and planned works on the times you travel.
struct AlertStatus: Decodable, Sendable {
    var checkedAt: Date
    var alerts: [Entry]

    struct Entry: Decodable, Sendable {
        var id: String
        var issues: [Issue]
        var upcoming: [Issue]
    }

    struct Issue: Decodable, Hashable, Sendable, Identifiable {
        var severity: String
        var title: String
        var detail: String
        var from: Date?

        var id: String { title + detail }
        var level: ServiceNotice.Severity {
            switch severity {
            case "closed": .closed
            case "delays": .delays
            default: .minor
            }
        }
    }

    static func decode(_ data: Data) throws -> AlertStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Time.iso(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return try decoder.decode(AlertStatus.self, from: data).bounded()
    }

    /// The server is whatever address was entered, so what it says is kept to a size the
    /// screen can show: a title of 120 characters, a notice of 1,500, ten issues an alert.
    static let maxTitle = 120, maxDetail = 1_500, maxIssues = 10

    func bounded() -> AlertStatus {
        func cut(_ issues: [Issue]) -> [Issue] {
            issues.prefix(Self.maxIssues).map {
                Issue(severity: String($0.severity.prefix(16)), title: String($0.title.prefix(Self.maxTitle)),
                      detail: String($0.detail.prefix(Self.maxDetail)), from: $0.from)
            }
        }
        return AlertStatus(checkedAt: checkedAt, alerts: alerts.prefix(64).map {
            Entry(id: String($0.id.prefix(64)), issues: cut($0.issues), upcoming: cut($0.upcoming))
        })
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
