import Foundation

/// Departure boards from Transitous's stop times: what leaves a stop, live where
/// the feed has it, and where each one calls next. One request per board, made
/// when a board is shown, so it stays within Transitous's light-use policy.
struct DepartureProvider: Sendable {
    /// A board starts this long before the planned departure, so the ones you
    /// just missed (or could still make) show above yours.
    static let boardLead: TimeInterval = 20 * 60
    static let boardSpan: TimeInterval = 50 * 60
    /// A stop off this close to where the journey gets off counts as the same
    /// stop. Tight on purpose: Cannon Street is 250 m from Bank.
    static let sameStopDistance: Double = 200

    func board(for leg: Leg) async throws -> DepartureBoard {
        guard let request = Self.boardRequest(for: leg) else { throw ProviderError.noRoutes }
        return try Self.parseBoard(try await HTTP.data(for: request), for: leg)
    }

    func nearby(_ coordinate: Coordinate, now: Date = .now) async throws -> [NearbyLine] {
        try Self.parseNearby(try await HTTP.data(for: Self.nearbyRequest(coordinate, now: now)), around: coordinate, now: now)
    }

    static func boardRequest(for leg: Leg) -> URLRequest? {
        guard leg.mode.isTransit, let start = leg.start else { return nil }
        var items = [
            URLQueryItem(name: "center", value: start.pair),
            // Stations sprawl (and sources place them differently); bus stops don't.
            URLQueryItem(name: "radius", value: [.bus, .coach, .tram].contains(leg.mode) ? "80" : "200"),
            URLQueryItem(name: "time", value: Time.isoString(leg.departure.addingTimeInterval(-boardLead))),
            URLQueryItem(name: "window", value: String(Int(boardSpan))),
            URLQueryItem(name: "n", value: "1"),
            URLQueryItem(name: "fetchStops", value: "true"),
        ]
        if let mode = queryMode(leg.mode) { items.append(URLQueryItem(name: "mode", value: mode)) }
        return request(items)
    }

    static func nearbyRequest(_ coordinate: Coordinate, now: Date) -> URLRequest {
        request([
            URLQueryItem(name: "center", value: coordinate.pair),
            URLQueryItem(name: "radius", value: "400"),
            URLQueryItem(name: "time", value: Time.isoString(now)),
            URLQueryItem(name: "n", value: "60"),
            URLQueryItem(name: "withAlerts", value: "false"),
        ])
    }

    private static func request(_ items: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(string: "https://api.transitous.org/api/v6/stoptimes")!
        components.queryItems = items
        return URLRequest(url: components.url!)
    }

    /// Narrows a busy station to the right kind of vehicle. Rail, DLR and the
    /// Elizabeth line are left open: feeds disagree on what to call them.
    private static func queryMode(_ mode: LegMode) -> String? {
        switch mode {
        case .tube: "SUBWAY"
        case .bus: "BUS"
        case .coach: "COACH,BUS"
        case .tram: "TRAM"
        case .ferry: "FERRY"
        default: nil
        }
    }

    // MARK: Parsing

    static func parseBoard(_ data: Data, for leg: Leg) throws -> DepartureBoard {
        let response = try HTTP.decode(Response.self, from: data)
        let wantedLine = leg.line.map(Journey.normalise)
        var seen = Set<String>()
        var departures: [Departure] = []
        var alerts: [ServiceAlert] = []

        for time in response.stopTimes where seen.insert(time.tripId ?? UUID().uuidString).inserted {
            guard var departure = departure(time) else { continue }
            let sameLine = wantedLine != nil && Journey.normalise(departure.line) == wantedLine
            // Anything that calls where the journey gets off is a way there; without
            // the trip's stops to check, fall back to the same line.
            if let stops = time.nextStops, !stops.isEmpty {
                guard let there = stops.first(where: { isAlighting($0, for: leg) }) else { continue }
                departure.arrivalThere = Time.iso(there.arrival) ?? Time.iso(there.scheduledArrival)
                guard sameLine || departure.mode == leg.mode else { continue }
            } else if !sameLine {
                continue
            }
            departures.append(departure)
            if sameLine, let line = leg.line {
                for alert in time.place.alerts ?? [] {
                    guard let header = alert.headerText, !header.isEmpty, concerns(alert, line: line) else { continue }
                    let item = ServiceAlert(header: header, detail: alert.descriptionText)
                    if !alerts.contains(item) { alerts.append(item) }
                }
            }
        }
        departures.sort { $0.expected < $1.expected }

        // The planned one: same line, leaving when the journey said it would.
        let candidates = departures.filter { wantedLine == nil || Journey.normalise($0.line) == wantedLine }
        let planned = (candidates.isEmpty ? departures : candidates)
            .map { ($0, min(abs($0.scheduled.timeIntervalSince(leg.departure)), abs($0.expected.timeIntervalSince(leg.departure)))) }
            .filter { $0.1 <= 150 }
            .min { $0.1 < $1.1 }?.0

        return DepartureBoard(
            stopName: planned?.stopName ?? departures.first?.stopName ?? leg.fromName,
            departures: departures, plannedID: planned?.id,
            // Line news before station notices, which run long.
            alerts: alerts.sorted { ($0.detail?.count ?? 0) < ($1.detail?.count ?? 0) })
    }

    static func parseNearby(_ data: Data, around center: Coordinate, now: Date) throws -> [NearbyLine] {
        let response = try HTTP.decode(Response.self, from: data)
        var groups: [String: NearbyLine] = [:]
        for time in response.stopTimes {
            guard let departure = departure(time), !departure.isCancelled,
                  departure.expected > now.addingTimeInterval(-30) else { continue }
            let distance = departure.stopCoordinate.distance(to: center)
            let key = "\(departure.line)|\(departure.headsign)"
            if var group = groups[key] {
                // Each line and direction from its nearest stop only.
                if distance < group.distance - 1 {
                    group = NearbyLine(line: departure.line, mode: departure.mode, lineColor: departure.lineColor,
                                       headsign: departure.headsign, stopName: departure.stopName,
                                       stopCoordinate: departure.stopCoordinate, distance: distance, departures: [departure])
                } else if departure.stopName == group.stopName {
                    group.departures.append(departure)
                }
                groups[key] = group
            } else {
                groups[key] = NearbyLine(line: departure.line, mode: departure.mode, lineColor: departure.lineColor,
                                         headsign: departure.headsign, stopName: departure.stopName,
                                         stopCoordinate: departure.stopCoordinate, distance: distance, departures: [departure])
            }
        }
        return groups.values
            .map { group in
                var group = group
                group.departures = Array(group.departures.sorted { $0.expected < $1.expected }.prefix(3))
                return group
            }
            // Nearest first, in 100 m bands so a stop next door doesn't bury a sooner bus.
            .sorted { a, b in
                let (bandA, bandB) = (Int(a.distance / 100), Int(b.distance / 100))
                if bandA != bandB { return bandA < bandB }
                return (a.departures.first?.expected ?? .distantFuture) < (b.departures.first?.expected ?? .distantFuture)
            }
    }

    private static func departure(_ time: Response.StopTime) -> Departure? {
        let place = time.place
        guard let scheduled = Time.iso(place.scheduledDeparture) ?? Time.iso(place.departure),
              time.pickupDropoffType != "NOT_ALLOWED" || time.cancelled == true else { return nil }
        let base = TransitousProvider.mode(time.mode)
        guard let line = TransitousProvider.lineName(base, routeShortName: time.routeShortName, displayName: time.displayName,
                                                     tripShortName: time.tripShortName, agencyName: time.agencyName) else { return nil }
        let mode = base.refined(line: line, agency: time.agencyName)
        return Departure(
            id: "\(time.tripId ?? line)|\(place.scheduledDeparture ?? "")",
            line: line, mode: mode,
            lineColor: LineColors.color(line: line, mode: mode, providerHex: time.routeColor),
            headsign: time.headsign ?? "",
            stopName: place.name,
            stopCoordinate: Coordinate(latitude: place.lat, longitude: place.lon),
            scheduled: scheduled,
            expected: Time.iso(place.departure) ?? scheduled,
            isRealtime: time.realTime ?? false,
            isCancelled: time.cancelled == true || place.cancelled == true,
            platform: place.track.flatMap { $0.isEmpty || $0 == "-" ? nil : $0 })
    }

    /// A stop's alerts cover every line through it: keep the ones about this
    /// line, and station notices that name no line at all.
    static func concerns(_ alert: Response.Alert, line: String) -> Bool {
        let text = Journey.normalise("\(alert.headerText ?? "") \(alert.descriptionText ?? "")")
        if text.contains(Journey.normalise(line)) { return true }
        return !LineColors.namedLines.contains { text.contains($0) }
    }

    private static func isAlighting(_ stop: Response.Place, for leg: Leg) -> Bool {
        guard stop.dropoffType != "NOT_ALLOWED" else { return false }
        let wanted = Journey.normalise(TfLProvider.cleanName(leg.toName))
        if !wanted.isEmpty, Journey.normalise(TfLProvider.cleanName(stop.name)) == wanted { return true }
        guard let end = leg.end else { return false }
        return Coordinate(latitude: stop.lat, longitude: stop.lon).distance(to: end) <= sameStopDistance
    }

    struct Response: Decodable {
        var stopTimes: [StopTime]

        struct StopTime: Decodable {
            var place: Place
            var mode: String
            var realTime: Bool?
            var headsign: String?
            var tripId: String?
            var agencyName: String?
            var routeShortName: String?
            var displayName: String?
            var tripShortName: String?
            var routeColor: String?
            var cancelled: Bool?
            var pickupDropoffType: String?
            var nextStops: [Place]?
        }
        struct Place: Decodable {
            var name: String
            var lat: Double
            var lon: Double
            var arrival: String?
            var departure: String?
            var scheduledArrival: String?
            var scheduledDeparture: String?
            var track: String?
            var cancelled: Bool?
            var dropoffType: String?
            var alerts: [Alert]?
        }
        struct Alert: Decodable {
            var headerText: String?
            var descriptionText: String?
        }
    }
}
