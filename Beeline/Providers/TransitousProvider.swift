import Foundation

/// Transitous: community-run MOTIS router over open timetables (GB rail, BODS
/// buses, Underground). One request per search; their policy asks for light use.
struct TransitousProvider: JourneyProvider {
    let id = ProviderID.transitous

    func journeys(for query: JourneyQuery, deep: Bool) async throws -> [Journey] {
        var components = URLComponents(string: "https://api.transitous.org/api/v5/plan")!
        components.queryItems = [
            URLQueryItem(name: "fromPlace", value: query.origin.coordinate.pair),
            URLQueryItem(name: "toPlace", value: query.destination.coordinate.pair),
            URLQueryItem(name: "time", value: Time.isoString(query.time.date)),
            URLQueryItem(name: "arriveBy", value: query.time.isArriveBy ? "true" : "false"),
            URLQueryItem(name: "numItineraries", value: deep ? "8" : "5"),
        ]
        return try Self.parse(try await HTTP.data(for: URLRequest(url: components.url!)),
                              origin: query.origin.name, destination: query.destination.name)
    }

    static func parse(_ data: Data, origin: String = "", destination: String = "") throws -> [Journey] {
        let response = try HTTP.decode(Response.self, from: data)
        let itineraries = (response.itineraries ?? []) + (response.direct ?? [])
        let journeys = itineraries.compactMap { it -> Journey? in
            guard let start = Time.iso(it.startTime), let end = Time.iso(it.endTime) else { return nil }
            // MOTIS names the request's own endpoints "START" and "END".
            let legs = it.legs.compactMap(leg).map { leg in
                var leg = leg
                if leg.fromName == "START" { leg.fromName = origin }
                if leg.toName == "END" { leg.toName = destination }
                return leg
            }
            return Journey(
                departure: start, arrival: end, legs: legs,
                sources: [SourceTag(provider: .transitous, variant: "Fastest")])
        }
        guard !journeys.isEmpty else { throw ProviderError.noRoutes }
        return journeys
    }

    private static func leg(_ l: Response.Leg) -> Leg? {
        guard let dep = Time.iso(l.startTime), let arr = Time.iso(l.endTime) else { return nil }
        let base = mode(l.mode)
        let rawLine = lineName(base, routeShortName: l.routeShortName, displayName: l.displayName,
                               tripShortName: l.tripShortName, agencyName: l.agencyName)
        let mode = base.refined(line: rawLine, agency: l.agencyName)
        let path = l.legGeometry.map { Polyline.decode($0.points, precision: $0.precision ?? 6) } ?? []
        return Leg(
            mode: mode, line: mode.isTransit ? rawLine : nil,
            lineColor: mode.isTransit ? LineColors.color(line: rawLine, mode: mode, providerHex: l.routeColor) : nil,
            headsign: l.headsign,
            fromName: l.from.name, toName: l.to.name,
            departure: dep, arrival: arr,
            stopCount: mode.isTransit ? (l.intermediateStops?.count ?? 0) + 1 : nil,
            distanceMeters: l.distance,
            path: path,
            isRealtime: l.realTime ?? false,
            platform: mode.isTransit ? l.from.track.flatMap { $0.isEmpty || $0 == "-" ? nil : $0 } : nil,
            intermediateStops: (l.intermediateStops ?? []).map(\.name))
    }

    /// Rail legs often carry only a trip number as their name; the operator reads better.
    static func lineName(_ mode: LegMode, routeShortName: String?, displayName: String?,
                         tripShortName: String?, agencyName: String?) -> String? {
        let named = [routeShortName, displayName].compactMap { $0 }.first { !$0.isEmpty }
        return mode == .rail && (named == nil || named == tripShortName) ? agencyName : (named ?? agencyName)
    }

    static func mode(_ mode: String) -> LegMode {
        switch mode {
        case "WALK": .walk
        case "BIKE", "RENTAL", "SCOOTER": .cycle
        case "BUS", "TROLLEYBUS": .bus
        case "COACH": .coach
        case "SUBWAY", "METRO": .tube
        case "TRAM", "CABLE_CAR": .tram
        case "RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "SUBURBAN": .rail
        case "FERRY": .ferry
        case "AERIAL_LIFT", "FUNICULAR": .cableCar
        default: .other
        }
    }

    struct Response: Decodable {
        var itineraries: [Itinerary]?
        var direct: [Itinerary]?

        struct Itinerary: Decodable {
            var startTime: String
            var endTime: String
            var legs: [Leg]
        }
        struct Leg: Decodable {
            var mode: String
            var from: Stop
            var to: Stop
            var startTime: String
            var endTime: String
            var realTime: Bool?
            var headsign: String?
            var routeShortName: String?
            var displayName: String?
            var tripShortName: String?
            var agencyName: String?
            var routeColor: String?
            var distance: Double?
            var intermediateStops: [Stop]?
            var legGeometry: Geometry?
        }
        struct Stop: Decodable {
            var name: String
            var track: String?
        }
        struct Geometry: Decodable {
            var points: String
            var precision: Int?
        }
    }
}
