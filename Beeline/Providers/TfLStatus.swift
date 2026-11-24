import Foundation

/// TfL's view of the whole network right now: every line's status, and every
/// station that's closed or skipped. It's checked against every source's routes,
/// because the planner that knew about a closure routes round it and says nothing,
/// while the ones that didn't know put you straight through it.
struct NetworkStatus: Sendable {
    struct Line: Sendable {
        var name: String
        var key: String
        /// TfL's severity: 10 is good service, lower is worse.
        var severity: Int
        var summary: String
        var reason: String
        var isNationalRail: Bool
        var periods: [ClosedRange<Date>]
    }

    struct Stop: Sendable {
        var name: String
        var key: String
        var mode: LegMode
        /// The whole station is shut, rather than part of it or one line through it.
        var isClosure: Bool
        var description: String
        var period: ClosedRange<Date>?
        /// The line the notice is about when it opens with one ("WINDRUSH LINE: …").
        var line: String?
    }

    var lines: [Line]
    var stops: [Stop]

    static let modes = "tube,dlr,elizabeth-line,overground,tram,national-rail"

    static func requests(appKey: String?) -> [URLRequest] {
        ["Line/Mode/\(modes)/Status", "StopPoint/Mode/\(modes)/Disruption"].map { path in
            var components = URLComponents(string: "https://api.tfl.gov.uk/\(path)")!
            if let appKey, !appKey.isEmpty { components.queryItems = [URLQueryItem(name: "app_key", value: appKey)] }
            return URLRequest(url: components.url!)
        }
    }

    static func fetch(appKey: String?) async throws -> NetworkStatus {
        let requests = requests(appKey: appKey)
        async let lines = HTTP.data(for: requests[0])
        async let stops = HTTP.data(for: requests[1])
        return try parse(lines: try await lines, stops: try await stops)
    }

    static func parse(lines: Data, stops: Data) throws -> NetworkStatus {
        let lineDTOs = try HTTP.decode([LineDTO].self, from: lines)
        let parsedLines = lineDTOs.flatMap { line in
            line.lineStatuses.map { status in
                Line(name: line.name, key: Journey.normalise(line.name), severity: status.statusSeverity,
                     summary: status.statusSeverityDescription, reason: status.reason ?? "",
                     isNationalRail: line.modeName == "national-rail",
                     periods: (status.validityPeriods ?? []).compactMap { period in
                         guard let from = Time.iso(period.fromDate), let to = Time.iso(period.toDate), from <= to else { return nil }
                         return from...to
                     })
            }
        }
        let lineKeys = Set(parsedLines.map(\.key))
        let parsedStops: [Stop] = try HTTP.decode([StopDTO].self, from: stops).compactMap { stop in
            guard stop.type == "Closure" || stop.type == "Part Closure", let mode = mode(stop.mode),
                  let name = stop.commonName, let description = stop.description else { return nil }
            let from = Time.iso(stop.fromDate), to = Time.iso(stop.toDate)
            // "MILDMAY LINE: no service between …" is about that line only, though it's listed
            // against every station on the way, which other lines share.
            let opening = description.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            let line = description.contains(":") && lineKeys.contains(Journey.normalise(opening)) ? Journey.normalise(opening) : nil
            return Stop(name: TfLProvider.cleanName(name), key: stationKey(name), mode: mode, isClosure: stop.type == "Closure",
                        description: description, period: from.flatMap { f in to.flatMap { f <= $0 ? f...$0 : nil } }, line: line)
        }
        return NetworkStatus(lines: parsedLines, stops: parsedStops)
    }

    // MARK: Matching

    /// What TfL says about each ride in a journey.
    func notices(for journey: Journey) -> [ServiceNotice] {
        journey.legs.filter(\.mode.isTransit).flatMap(notices(for:))
    }

    func notices(for leg: Leg) -> [ServiceNotice] {
        let mode = leg.mode.refined(line: leg.line, agency: nil)
        guard [.tube, .dlr, .elizabeth, .overground, .tram, .rail].contains(mode) else { return [] }
        let lineKey = leg.line.map(Journey.normalise)
        let label = leg.line ?? mode.label
        let ends = [leg.fromName, leg.toName].map(Self.stationKey)
        let calls = ends + leg.intermediateStops.map(Self.stationKey)

        var found: [ServiceNotice] = []
        // Stations, grouped by notice: one closure is listed against every station it covers.
        let relevant = stops.filter { stop in
            stop.mode == mode && (stop.period?.contains(leg.departure) ?? true)
                && (stop.line == nil || lineKey == nil || stop.line == lineKey)
        }
        for (description, group) in Dictionary(grouping: relevant, by: \.description).sorted(by: { $0.key < $1.key }) {
            let keys = Set(group.map(\.key))
            let lower = description.lowercased()
            if lower.contains("no service") || lower.contains("suspended") {
                // A stretch of line: riding within it (two of its stations) won't work; touching
                // one end of it may well, since the end station is usually still served.
                let touched = Set(calls).intersection(keys)
                guard !touched.isEmpty else { continue }
                found.append(ServiceNotice(title: "Part closure on the \(label)", detail: description,
                                           severity: touched.count >= 2 ? .closed : .delays, source: .tfl, leg: leg.id))
            } else if let stop = group.first(where: { ends.contains($0.key) }) {
                // One station. Trains not calling one way only still call the other way.
                let oneWay = ["westbound", "eastbound", "northbound", "southbound"].contains { lower.contains($0) }
                found.append(ServiceNotice(
                    title: stop.isClosure ? "\(stop.name) station closed" : "\(stop.name) part closed (\(label))",
                    detail: description, severity: stop.isClosure || !oneWay ? .closed : .delays, source: .tfl, leg: leg.id))
            }
        }

        // The line's own status. A part closure is better told by its stations above.
        if let lineKey {
            for line in lines where line.key == lineKey && (line.periods.isEmpty || line.periods.contains { $0.contains(leg.departure) }) {
                guard var severity = Self.severity(line.severity) else { continue }
                if [3, 5, 11].contains(line.severity) {
                    if !found.isEmpty { continue }
                    severity = .minor
                }
                let name = line.isNationalRail ? line.name : "the \(line.name)"
                let summary = line.summary.prefix(1).uppercased() + line.summary.dropFirst().lowercased()
                found.append(ServiceNotice(title: severity == .closed ? "\(line.name): \(summary.lowercased())" : "\(summary) on \(name)",
                                           detail: line.reason, severity: severity, source: .tfl, leg: leg.id))
            }
        }
        var seen = Set<ServiceNotice.DisplayID>()
        return found.filter { seen.insert($0.displayID).inserted }
    }

    /// How much a line status matters to a route on that line; nil when it doesn't.
    static func severity(_ tfl: Int) -> ServiceNotice.Severity? {
        switch tfl {
        case 1, 2, 4, 16, 20: .closed
        case 6, 7, 8, 15, 17: .delays
        case 3, 5, 9, 11: .minor
        // Good service, step-free notes, and National Rail's "special service" (a link to its site).
        default: nil
        }
    }

    static func mode(_ tfl: String?) -> LegMode? {
        switch tfl {
        case "tube": .tube
        case "dlr": .dlr
        case "elizabeth-line": .elizabeth
        case "overground": .overground
        case "tram": .tram
        case "national-rail": .rail
        default: nil
        }
    }

    /// Station names as different sources spell them: "Shepherd's Bush", "Shepherds Bush Rail Station".
    static func stationKey(_ name: String) -> String {
        var name = name.lowercased()
        while let open = name.firstIndex(of: "("), let close = name[open...].firstIndex(of: ")") { name.removeSubrange(open...close) }
        for suffix in [" underground station", " rail station", " dlr station", " station"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name.replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
    }

    struct LineDTO: Decodable {
        var name: String
        var modeName: String?
        var lineStatuses: [StatusDTO]
    }

    struct StatusDTO: Decodable {
        var statusSeverity: Int
        var statusSeverityDescription: String
        var reason: String?
        var validityPeriods: [Period]?

        struct Period: Decodable {
            var fromDate: String?
            var toDate: String?
        }
    }

    struct StopDTO: Decodable {
        var commonName: String?
        var description: String?
        var type: String?
        var mode: String?
        var fromDate: String?
        var toDate: String?
    }
}
