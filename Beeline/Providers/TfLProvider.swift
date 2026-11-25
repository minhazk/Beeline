import Foundation

/// TfL Unified API Journey Planner: London's official planner, including National
/// Rail in and around London. Works without a key at 50 requests/minute.
struct TfLProvider: JourneyProvider {
    let id = ProviderID.tfl
    var appKey: String?

    struct Variant: Sendable {
        var preference: String
        var label: String
    }

    static let variants = [
        Variant(preference: "leasttime", label: "Fastest"),
        Variant(preference: "leastinterchange", label: "Fewer changes"),
        Variant(preference: "leastwalking", label: "Less walking"),
    ]

    func journeys(for query: JourneyQuery, deep: Bool) async throws -> [Journey] {
        try await fanOut(deep ? Self.variants : [Self.variants[0]]) { variant in
            try Self.parse(try await HTTP.data(for: request(query, preference: variant.preference)), variant: variant.label)
        }
    }

    func request(_ query: JourneyQuery, preference: String) -> URLRequest {
        var components = URLComponents(string: "https://api.tfl.gov.uk/Journey/JourneyResults/\(query.origin.coordinate.pair)/to/\(query.destination.coordinate.pair)")!
        var items = [URLQueryItem(name: "journeyPreference", value: preference)]
        if query.time != .leaveNow {
            let c = Time.londonComponents(query.time.date)
            items.append(URLQueryItem(name: "date", value: String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)))
            items.append(URLQueryItem(name: "time", value: String(format: "%02d%02d", c.hour!, c.minute!)))
            items.append(URLQueryItem(name: "timeIs", value: query.time.isArriveBy ? "Arriving" : "Departing"))
        }
        if let appKey, !appKey.isEmpty { items.append(URLQueryItem(name: "app_key", value: appKey)) }
        components.queryItems = items
        return URLRequest(url: components.url!)
    }

    static func parse(_ data: Data, variant: String) throws -> [Journey] {
        let response = try HTTP.decode(Response.self, from: data)
        guard let journeys = response.journeys, !journeys.isEmpty else { throw ProviderError.noRoutes }
        return journeys.prefix(TransitousProvider.maxItineraries).compactMap { j in
            guard let start = Time.londonLocal(j.startDateTime), let end = Time.londonLocal(j.arrivalDateTime),
                  end >= start, j.legs.count <= TransitousProvider.maxLegs else { return nil }
            let legs = j.legs.compactMap(leg)
            // All of it or none: a route missing a leg that couldn't be read would be shown, and
            // followed in Go, as if that change weren't there.
            guard !legs.isEmpty, legs.count == j.legs.count, Leg.inOrder(legs) else { return nil }
            return Journey(
                departure: start, arrival: end, legs: legs,
                sources: [SourceTag(provider: .tfl, variant: variant)],
                fare: j.fare?.totalCost.flatMap { $0 > 0 ? String(format: "£%.2f", Double($0) / 100) : nil },
                hasDisruption: j.legs.contains { $0.isDisrupted == true })
        }
    }

    private static func leg(_ l: Response.Leg) -> Leg? {
        guard let dep = Time.londonLocal(l.departureTime), let arr = Time.londonLocal(l.arrivalTime), arr >= dep else { return nil }
        let option = l.routeOptions?.first
        let lineID = option?.lineIdentifier?.id
        var mode = mode(l.mode?.id)
        let rawLine = option?.name.flatMap { $0.isEmpty ? nil : $0 }
        mode = mode.refined(line: rawLine, agency: nil)
        let line = mode.isTransit ? rawLine : nil
        let path = (l.path?.lineString?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([[Double]].self, from: $0) } ?? []
        let realtime = l.scheduledDepartureTime != nil && l.scheduledDepartureTime != l.departureTime
        return Leg(
            mode: mode, line: line,
            lineColor: mode.isTransit ? LineColors.color(line: lineID ?? line, mode: mode) : nil,
            headsign: option?.directions?.first,
            fromName: cleanName(l.departurePoint?.commonName),
            toName: cleanName(l.arrivalPoint?.commonName),
            departure: dep, arrival: arr,
            stopCount: mode.isTransit ? l.path?.stopPoints?.count : nil,
            distanceMeters: l.distance.flatMap(\.plausibleMetres),
            path: path.prefix(Polyline.maxPoints).compactMap { $0.count == 2 ? Coordinate.checked(latitude: $0[0], longitude: $0[1]) : nil },
            isRealtime: realtime,
            platform: l.departurePoint?.platformName.flatMap { $0.isEmpty ? nil : $0 },
            // stopPoints ends with the alighting stop.
            intermediateStops: mode.isTransit ? Array((l.path?.stopPoints ?? []).compactMap { $0.name.map(cleanName) }.dropLast()) : [])
    }

    static func mode(_ id: String?) -> LegMode {
        switch id {
        case "walking": .walk
        case "bus", "replacement-bus": .bus
        case "tube": .tube
        case "overground": .overground
        case "elizabeth-line": .elizabeth
        case "dlr": .dlr
        case "tram": .tram
        case "national-rail", "international-rail": .rail
        case "river-bus", "river-tour": .ferry
        case "cable-car": .cableCar
        case "coach": .coach
        case "cycle", "cycle-hire": .cycle
        default: .other
        }
    }

    static func cleanName(_ name: String?) -> String {
        var name = name ?? ""
        for suffix in [" Underground Station", " Rail Station", " DLR Station", " Station"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    struct Response: Decodable {
        var journeys: [JourneyDTO]?

        struct JourneyDTO: Decodable {
            var startDateTime: String?
            var arrivalDateTime: String?
            var legs: [Leg]
            var fare: Fare?
        }
        struct Fare: Decodable { var totalCost: Int? }
        struct Leg: Decodable {
            var departureTime: String?
            var arrivalTime: String?
            var scheduledDepartureTime: String?
            var departurePoint: Point?
            var arrivalPoint: Point?
            var path: Path?
            var routeOptions: [RouteOption]?
            var mode: Identifier?
            var isDisrupted: Bool?
            var distance: Double?
        }
        struct Point: Decodable {
            var commonName: String?
            var platformName: String?
        }
        struct Path: Decodable {
            var lineString: String?
            var stopPoints: [Identifier]?
        }
        struct RouteOption: Decodable {
            var name: String?
            var directions: [String]?
            var lineIdentifier: Identifier?
        }
        struct Identifier: Decodable {
            var id: String?
            var name: String?
        }
    }
}
