import Foundation

/// Google Routes API, TRANSIT mode. The key is restricted to this app's bundle ID,
/// which Google checks via the X-Ios-Bundle-Identifier header.
struct GoogleRoutesProvider: JourneyProvider {
    let id = ProviderID.google
    var apiKey: String?
    var bundleID = Bundle.main.bundleIdentifier ?? ""
    /// How many requests this search may send (`GoogleAllowance.searchRequests`): its deep-search
    /// variants are cut to this many, in order.
    var maxRequests = Self.variants.count

    struct Variant: Sendable {
        var label: String
        var routingPreference: String?
        var modes: [String]?
    }

    static let variants = [
        Variant(label: "Fastest"),
        Variant(label: "Fewer changes", routingPreference: "FEWER_TRANSFERS"),
        Variant(label: "Less walking", routingPreference: "LESS_WALKING"),
        Variant(label: "Rail only", modes: ["TRAIN", "SUBWAY", "LIGHT_RAIL", "RAIL"]),
        Variant(label: "Bus only", modes: ["BUS"]),
    ]

    static let fieldMask = [
        "routes.duration", "routes.legs.steps.travelMode", "routes.legs.steps.staticDuration",
        "routes.legs.steps.distanceMeters", "routes.legs.steps.polyline", "routes.legs.steps.transitDetails",
        "routes.localizedValues.transitFare",
    ].joined(separator: ",")

    func journeys(for query: JourneyQuery, deep: Bool) async throws -> [Journey] {
        guard let apiKey, !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard maxRequests > 0 else { throw ProviderError.missingKey }
        return try await fanOut(deep ? Array(Self.variants.prefix(maxRequests)) : [Self.variants[0]]) { variant in
            try Self.parse(try await HTTP.data(for: request(query, variant: variant, key: apiKey)), query: query, variant: variant.label)
        }
    }

    func request(_ query: JourneyQuery, variant: Variant, key: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue(Self.fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")

        var body = Body(
            origin: .init(query.origin.coordinate), destination: .init(query.destination.coordinate),
            transitPreferences: .init(allowedTravelModes: variant.modes, routingPreference: variant.routingPreference))
        switch query.time {
        case .leaveNow: break
        case .departAt(let date): body.departureTime = Time.isoString(date)
        case .arriveBy(let date): body.arrivalTime = Time.isoString(date)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func parse(_ data: Data, query: JourneyQuery, variant: String) throws -> [Journey] {
        let response = try HTTP.decode(Response.self, from: data)
        let journeys = (response.routes ?? []).compactMap { journey($0, query: query, variant: variant) }
        guard !journeys.isEmpty else { throw ProviderError.noRoutes }
        return journeys
    }

    /// Google times only its transit steps. Walks are placed around them: the
    /// first ends as the first vehicle leaves, later ones start when you alight.
    private static func journey(_ route: Response.Route, query: JourneyQuery, variant: String) -> Journey? {
        let steps = route.legs?.flatMap { $0.steps ?? [] } ?? []
        var legs: [Leg] = []
        var pendingWalk: (seconds: TimeInterval, meters: Double, path: [Coordinate])?

        func flushWalk(endingAt end: Date?, startingAt start: Date?) {
            guard let walk = pendingWalk else { return }
            pendingWalk = nil
            let departure = start ?? end.map { $0.addingTimeInterval(-walk.seconds) } ?? query.time.date
            legs.append(Leg(
                mode: .walk, fromName: legs.last?.toName ?? query.origin.name, toName: "",
                departure: departure, arrival: departure.addingTimeInterval(walk.seconds),
                distanceMeters: walk.meters, path: walk.path))
        }

        for step in steps {
            let points = step.polyline?.encodedPolyline.map { Polyline.decode($0) } ?? []
            guard step.travelMode == "TRANSIT", let t = step.transitDetails,
                  let dep = Time.iso(t.stopDetails?.departureTime), let arr = Time.iso(t.stopDetails?.arrivalTime) else {
                var walk = pendingWalk ?? (0, 0, [])
                walk.seconds += seconds(step.staticDuration)
                walk.meters += Double(step.distanceMeters ?? 0)
                walk.path += points
                pendingWalk = walk
                continue
            }
            let previousArrival = legs.last?.arrival
            flushWalk(endingAt: dep, startingAt: previousArrival)
            let fromName = t.stopDetails?.departureStop?.name ?? ""
            if let last = legs.indices.last, legs[last].mode == .walk, legs[last].toName.isEmpty { legs[last].toName = fromName }

            let line = t.transitLine
            let agency = line?.agencies?.first?.name
            let base = mode(line?.vehicle?.type)
            // The short name is the bus number, or TfL's own line name ("Northern", not "Northern Line").
            let shortName = line?.nameShort.flatMap { $0.isEmpty ? nil : $0 }
            let rawLine = shortName ?? line?.name ?? agency
            let refined = base.refined(line: rawLine, agency: agency)
            legs.append(Leg(
                mode: refined, line: rawLine,
                lineColor: LineColors.color(line: rawLine, mode: refined, providerHex: line?.color),
                headsign: t.headsign, fromName: fromName, toName: t.stopDetails?.arrivalStop?.name ?? "",
                departure: dep, arrival: arr, stopCount: t.stopCount,
                distanceMeters: step.distanceMeters.map(Double.init), path: points))
        }
        let lastArrival = legs.last?.arrival
        flushWalk(endingAt: nil, startingAt: lastArrival ?? walkOnlyStart(route, query: query))
        if let last = legs.indices.last, legs[last].mode == .walk { legs[last].toName = query.destination.name }

        guard let first = legs.first, let last = legs.last else { return nil }
        return Journey(
            departure: first.departure, arrival: last.arrival, legs: legs,
            sources: [SourceTag(provider: .google, variant: variant)],
            fare: route.localizedValues?.transitFare?.text)
    }

    private static func walkOnlyStart(_ route: Response.Route, query: JourneyQuery) -> Date {
        query.time.isArriveBy ? query.time.date.addingTimeInterval(-seconds(route.duration)) : query.time.date
    }

    static func seconds(_ duration: String?) -> TimeInterval {
        TimeInterval(duration?.trimmingCharacters(in: CharacterSet(charactersIn: "s")) ?? "") ?? 0
    }

    static func mode(_ vehicle: String?) -> LegMode {
        switch vehicle {
        case "BUS", "TROLLEYBUS", "SHARE_TAXI": .bus
        case "INTERCITY_BUS": .coach
        case "SUBWAY", "METRO_RAIL": .tube
        case "TRAM", "MONORAIL": .tram
        case "RAIL", "HEAVY_RAIL", "COMMUTER_TRAIN", "HIGH_SPEED_TRAIN", "LONG_DISTANCE_TRAIN": .rail
        case "FERRY": .ferry
        case "CABLE_CAR", "GONDOLA_LIFT", "FUNICULAR": .cableCar
        default: .other
        }
    }

    struct Body: Encodable {
        var origin: Waypoint
        var destination: Waypoint
        var travelMode = "TRANSIT"
        var computeAlternativeRoutes = true
        var transitPreferences: TransitPreferences
        var departureTime: String?
        var arrivalTime: String?

        struct Waypoint: Encodable {
            var location: Location
            init(_ c: Coordinate) { location = Location(latLng: LatLng(latitude: c.latitude, longitude: c.longitude)) }
        }
        struct Location: Encodable { var latLng: LatLng }
        struct LatLng: Encodable {
            var latitude: Double
            var longitude: Double
        }
        struct TransitPreferences: Encodable {
            var allowedTravelModes: [String]?
            var routingPreference: String?
        }
    }

    struct Response: Decodable {
        var routes: [Route]?

        struct Route: Decodable {
            var duration: String?
            var legs: [RouteLeg]?
            var localizedValues: LocalizedValues?
        }
        struct LocalizedValues: Decodable { var transitFare: Text? }
        struct Text: Decodable { var text: String? }
        struct RouteLeg: Decodable { var steps: [Step]? }
        struct Step: Decodable {
            var travelMode: String?
            var staticDuration: String?
            var distanceMeters: Int?
            var polyline: EncodedPolyline?
            var transitDetails: TransitDetails?
        }
        struct EncodedPolyline: Decodable { var encodedPolyline: String? }
        struct TransitDetails: Decodable {
            var stopDetails: StopDetails?
            var headsign: String?
            var stopCount: Int?
            var transitLine: TransitLine?
        }
        struct StopDetails: Decodable {
            var departureStop: Stop?
            var arrivalStop: Stop?
            var departureTime: String?
            var arrivalTime: String?
        }
        struct Stop: Decodable { var name: String? }
        struct TransitLine: Decodable {
            var name: String?
            var nameShort: String?
            var color: String?
            var vehicle: Vehicle?
            var agencies: [Agency]?
        }
        struct Vehicle: Decodable { var type: String? }
        struct Agency: Decodable { var name: String? }
    }
}
