import Foundation

/// TfL's lines and the stations along each, for choosing what to be alerted about.
/// One request for the list of lines and one per line opened, kept for the session.
@MainActor
enum TfLLines {
    struct Line: Identifiable, Hashable, Sendable {
        var id: String
        /// TfL's own: "District", "Elizabeth line", "Southeastern".
        var tflName: String
        var mode: String

        var legMode: LegMode { NetworkStatus.mode(mode)?.refined(line: tflName, agency: nil) ?? .rail }
        /// As people say it: "District line", "Mildmay line", "DLR".
        var name: String { ["tube", "overground"].contains(mode) && !tflName.lowercased().hasSuffix("line") ? "\(tflName) line" : tflName }
        var alertLine: RouteAlert.Line { RouteAlert.Line(id: id, name: name) }
    }

    /// One station on a line, with every id TfL uses for it there (the Elizabeth line's
    /// Liverpool Street is both its own platforms and the main-line station).
    struct Station: Identifiable, Hashable, Sendable {
        var ids: [String]
        var name: String
        /// Every spelling seen, for matching other sources' names.
        var names: [String]

        var id: String { ids.joined(separator: "|") }
        var alertStation: RouteAlert.Station { RouteAlert.Station(id: id, name: name) }
    }

    struct Route: Sendable {
        var stations: [Station]
        /// Each of the line's routes as station ids, in order.
        var sequences: [[String]]

        func station(named name: String) -> Station? {
            let key = NetworkStatus.stationKey(name)
            return stations.first { $0.names.contains { NetworkStatus.stationKey($0) == key } }
        }

        /// The stations between two, along the shortest of the line's routes that has both.
        func stretch(from: Station, to: Station) -> [Station]? {
            let byId = Dictionary(stations.flatMap { station in station.ids.map { ($0, station) } }, uniquingKeysWith: { a, _ in a })
            var best: [Station]?
            for sequence in sequences {
                guard let a = sequence.firstIndex(where: from.ids.contains), let b = sequence.firstIndex(where: to.ids.contains), a != b else { continue }
                let ids = a < b ? Array(sequence[a...b]) : Array(sequence[b...a].reversed())
                var run: [Station] = []
                for id in ids { if let s = byId[id], run.last != s { run.append(s) } }
                if best == nil || run.count < best!.count { best = run }
            }
            return best
        }

        func segment(_ line: Line, from: Station?, to: Station?) -> RouteAlert.Segment {
            guard let from, let to, let run = stretch(from: from, to: to) else {
                return RouteAlert.Segment(line: line.alertLine, mode: line.mode)
            }
            return RouteAlert.Segment(line: line.alertLine, mode: line.mode, from: from.alertStation, to: to.alertStation, stations: run.map(\.id))
        }
    }

    private static var cachedLines: [Line]?
    private static var cachedRoutes: [String: Route] = [:]

    static func lines() async throws -> [Line] {
        if let cachedLines { return cachedLines }
        let data = try await HTTP.data(for: URLRequest(url: URL(string: "https://api.tfl.gov.uk/Line/Mode/\(NetworkStatus.modes)")!))
        let lines = try parseLines(data)
        cachedLines = lines
        return lines
    }

    static func route(_ lineId: String) async throws -> Route {
        if let route = cachedRoutes[lineId] { return route }
        let url = URL(string: "https://api.tfl.gov.uk/Line/\(lineId)/Route/Sequence/all")!
        let route = try parseRoute(try await HTTP.data(for: URLRequest(url: url)))
        cachedRoutes[lineId] = route
        return route
    }

    nonisolated static func parseLines(_ data: Data) throws -> [Line] {
        struct DTO: Decodable { var id: String; var name: String; var modeName: String }
        return try HTTP.decode([DTO].self, from: data).map { Line(id: $0.id, tflName: $0.name, mode: $0.modeName) }
    }

    nonisolated static func parseRoute(_ data: Data) throws -> Route {
        struct Stop: Decodable { var id: String; var name: String; var topMostParentId: String? }
        struct Sequence: Decodable { var stopPoint: [Stop] }
        struct Ordered: Decodable { var naptanIds: [String] }
        struct DTO: Decodable {
            var stations: [Stop]?
            var stopPointSequences: [Sequence]?
            var orderedLineRoutes: [Ordered]?
        }
        let dto = try HTTP.decode(DTO.self, from: data)
        let sequences = (dto.orderedLineRoutes ?? []).map(\.naptanIds).filter { !$0.isEmpty }
        let onRoutes = Set(sequences.joined())
        let stops = (dto.stopPointSequences ?? []).flatMap(\.stopPoint) + (dto.stations ?? [])

        // Group by TfL's hub, so one station's several ids are one choice.
        var groups: [String: [Stop]] = [:]
        var order: [String] = []
        // The station list includes the hubs themselves ("HUBLST"), which no disruption names.
        for stop in stops where !stop.id.hasPrefix("HUB") {
            let key = stop.topMostParentId ?? stop.id
            if groups[key] == nil { order.append(key) }
            if !(groups[key]?.contains { $0.id == stop.id } ?? false) { groups[key, default: []].append(stop) }
        }
        let stations: [Station] = order.compactMap { key in
            let group = groups[key] ?? []
            // A hub's ids not on any of this line's routes only matter as aliases of one that is.
            guard group.contains(where: { onRoutes.contains($0.id) }) else { return nil }
            let ids = group.map(\.id).filter(onRoutes.contains) + group.map(\.id).filter { !onRoutes.contains($0) }
            let names = group.map { TfLProvider.cleanName($0.name) }.uniqued()
            let name = names.min { $0.count < $1.count } ?? key
            // The shortest spelling: "Liverpool Street" over "London Liverpool Street".
            return Station(ids: ids, name: name, names: names)
        }
        return Route(stations: stations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, sequences: sequences)
    }

    /// TfL's line for a ride another source found, by name ("Elizabeth line", "Central", "Mildmay").
    nonisolated static func line(for leg: Leg, in lines: [Line]) -> Line? {
        let mode = leg.mode.refined(line: leg.line, agency: nil)
        switch mode {
        case .dlr: return lines.first { $0.id == "dlr" }
        case .tram: return lines.first { $0.id == "tram" }
        case .tube, .elizabeth, .overground, .rail:
            guard let name = leg.line else { return nil }
            let key = Journey.normalise(name)
            return lines.first { Journey.normalise($0.tflName) == key }
        default: return nil
        }
    }

    /// An alert for the TfL lines in a journey, each from where you get on to where you get off.
    static func draft(for journey: Journey) async throws -> RouteAlert? {
        let lines = try await lines()
        var segments: [RouteAlert.Segment] = []
        for leg in journey.transitLegs {
            guard let line = line(for: leg, in: lines) else { continue }
            let route = try await route(line.id)
            let segment = route.segment(line, from: route.station(named: leg.fromName), to: route.station(named: leg.toName))
            if !segments.contains(segment) { segments.append(segment) }
        }
        guard !segments.isEmpty else { return nil }
        var alert = RouteAlert(segments: segments)
        let calendar = Calendar.current
        let weekday = (calendar.component(.weekday, from: journey.departure) + 5) % 7 + 1
        alert.days = weekday <= 5 ? Array(1...5) : [6, 7]
        // From an hour before you'd leave to when you'd arrive, in quarter hours.
        let minutes = { (date: Date) in calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
        let start = max(0, (minutes(journey.departure) - 60) / 15 * 15)
        let end = min(23 * 60 + 45, (minutes(journey.arrival) + 14) / 15 * 15)
        alert.windows = [RouteAlert.TimeWindow(start: start, end: end > start ? end : min(start + 120, 23 * 60 + 45))]
        return alert
    }
}
