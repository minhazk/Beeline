import Foundation

/// Where London's buses are. TfL doesn't publish bus GPS, only each bus's predicted
/// arrival at the stops ahead of it (Countdown), so a bus is placed between the
/// stop it last passed and the one it's due at next, by how soon it's due. That's
/// how other London apps draw them too. One request per line every 30 seconds
/// while a line is on screen (TfL caches it that long anyway), about 25 KB.
enum TfLBuses {
    /// One direction of a bus route: its stops in order and the road it takes.
    struct Route: Hashable, Sendable {
        var lineID: String
        var direction: String
        var stops: [Stop]
        var path: [Coordinate]
        /// Each stop's distance along `path`, rising, or nil where the path and stops disagree.
        var stopAlong: [Double]?

        struct Stop: Hashable, Sendable {
            var id: String
            var name: String
            /// The letter on the flag ("V"), when it has one.
            var letter: String?
            var coordinate: Coordinate
        }

        func index(of stopID: String) -> Int? { stops.firstIndex { $0.id == stopID } }

        /// The stop nearest a point, if one is close enough to be it.
        func nearestStop(to point: Coordinate, within limit: Double = 120, after: Int = -1) -> (index: Int, distance: Double)? {
            stops.indices.filter { $0 > after }
                .map { ($0, stops[$0].coordinate.distance(to: point)) }
                .filter { $0.1 <= limit }
                .min { $0.1 < $1.1 }
        }

        /// The point `fraction` of the way from one stop to the next, along the road where it can.
        func point(between from: Int, and to: Int, fraction: Double) -> (coordinate: Coordinate, heading: Double?) {
            let f = min(max(fraction, 0), 1)
            if let along = stopAlong, along[to] > along[from] {
                let distance = along[from] + (along[to] - along[from]) * f
                return Geometry.point(at: distance, on: path)
            }
            let (a, b) = (stops[from].coordinate, stops[to].coordinate)
            let c = Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * f, longitude: a.longitude + (b.longitude - a.longitude) * f)
            return (c, Geometry.bearing(from: a, to: b))
        }
    }

    /// One prediction: this bus at this stop at this time.
    struct Prediction: Hashable, Sendable {
        var vehicleID: String
        var stopID: String
        var direction: String
        var destination: String
        var expected: Date
    }

    /// A bus on the map.
    struct Bus: Identifiable, Hashable, Sendable {
        /// Its registration, which is all TfL calls it.
        var id: String
        var coordinate: Coordinate
        /// Degrees from north, the way it's going.
        var heading: Double?
        var destination: String
        /// The stop it's due at next, by index into the route's stops.
        var nextStop: Int
        /// When it's due at each stop ahead, by stop id.
        var due: [String: Date]
        /// Not started yet: at the first stop, or laying over there.
        var waiting = false
    }

    /// The lines TfL runs as buses: the name as people say it, in TfL's form ("N25" is "n25").
    static func lineID(_ line: String?) -> String? {
        guard let line else { return nil }
        let id = Journey.normalise(line)
        // It goes into the request's path: letters and digits as TfL writes them, nothing else.
        return id.isEmpty || id.count > 5 || !id.allSatisfy(\.isASCII) ? nil : id
    }

    static func routeRequest(_ lineID: String, direction: String, appKey: String?) -> URLRequest {
        request("Line/\(lineID)/Route/Sequence/\(direction)", appKey: appKey)
    }

    static func arrivalsRequest(_ lineID: String, appKey: String?) -> URLRequest {
        request("Line/\(lineID)/Arrivals", appKey: appKey)
    }

    private static func request(_ path: String, appKey: String?) -> URLRequest {
        var components = URLComponents(string: "https://api.tfl.gov.uk/\(path)")!
        if let appKey, !appKey.isEmpty { components.queryItems = [URLQueryItem(name: "app_key", value: appKey)] }
        return URLRequest(url: components.url!)
    }

    // MARK: Parsing

    static let maxSequences = 24, maxStops = 300
    /// Stop-to-point comparisons one reply may cost in fitting its stops to its drawn lines: a
    /// real route's are a few hundred thousand. Past this the stops themselves are the path.
    static let fittingBudget = 20_000_000

    /// Every way the route runs in one direction (most have one; some have short workings).
    static func parseRoutes(_ data: Data) throws -> [Route] {
        let response = try HTTP.decode(RouteDTO.self, from: data)
        // A route has a handful of drawn lines and a few dozen stops each way: far more is not a
        // route, and fitting every stop to every point of every line would take the app with it.
        let lines: [[Coordinate]] = response.lineStrings.prefix(Self.maxSequences).compactMap { string in
            guard let json = string.data(using: .utf8),
                  let nested = try? JSONDecoder().decode([[[Double]]].self, from: json) else { return nil }
            let points = nested.flatMap { $0 }.prefix(Polyline.maxPoints).compactMap { $0.count >= 2 ? Coordinate.checked(latitude: $0[1], longitude: $0[0]) : nil }
            return points.count > 1 ? points : nil
        }
        var budget = Self.fittingBudget
        return response.stopPointSequences.prefix(Self.maxSequences).compactMap { sequence in
            let stops = sequence.stopPoint.prefix(Self.maxStops).compactMap { stop -> Route.Stop? in
                guard let lat = stop.lat, let lon = stop.lon, let coordinate = Coordinate.checked(latitude: lat, longitude: lon) else { return nil }
                // Bus stop names are already as the flag says ("Stratford City Bus Station").
                return Route.Stop(id: stop.id, name: stop.name.trimmingCharacters(in: .whitespaces),
                                  letter: stop.stopLetter.flatMap { $0.isEmpty || $0.hasPrefix("->") ? nil : $0 },
                                  coordinate: coordinate)
            }
            guard stops.count > 1 else { return nil }
            // The drawn line these stops sit on best.
            var fits: [([Coordinate], (along: [Double], error: Double))] = []
            for line in lines {
                budget -= stops.count * line.count
                guard budget > 0 else { break }
                fits.append((line, Geometry.snap(stops.map(\.coordinate), to: line)))
            }
            let fitted = fits.min { $0.1.error < $1.1.error }
            let along = fitted.flatMap { $0.1.error < 40 ? $0.1.along : nil }
            return Route(lineID: response.lineId, direction: sequence.direction ?? response.direction ?? "",
                         stops: stops, path: fitted?.0 ?? stops.map(\.coordinate), stopAlong: along)
        }
    }

    static func parseArrivals(_ data: Data) throws -> [Prediction] {
        try HTTP.decode([ArrivalDTO].self, from: data).compactMap { a in
            guard let vehicle = a.vehicleId, !vehicle.isEmpty, let stop = a.naptanId,
                  let expected = Time.iso(a.expectedArrival) else { return nil }
            return Prediction(vehicleID: vehicle, stopID: stop, direction: a.direction ?? "",
                              destination: (a.destinationName ?? "").trimmingCharacters(in: .whitespaces), expected: expected)
        }
    }

    // MARK: Where they are

    /// Every bus on this route at `now`, placed between the stop it last passed and
    /// the one it's due at next. One still to start sits at the first stop, `waiting`.
    static func buses(on route: Route, from predictions: [Prediction], at now: Date) -> [Bus] {
        let index = Dictionary(route.stops.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byVehicle = Dictionary(grouping: predictions.filter { $0.direction == route.direction && index[$0.stopID] != nil },
                                   by: \.vehicleID)
        return byVehicle.compactMap { vehicle, predictions -> Bus? in
            // In stop order; a bus's predictions only ever run forwards along the route.
            let calls = predictions.map { (stop: index[$0.stopID]!, at: $0.expected) }.sorted { $0.stop < $1.stop }
            guard let nextCall = calls.firstIndex(where: { $0.at > now }) else { return nil }
            let next = calls[nextCall]
            let fraction: Double
            let from: Int
            if nextCall > 0, calls[nextCall - 1].stop < next.stop {
                // It's passed a stop we had a time for: between the two times.
                let last = calls[nextCall - 1]
                from = last.stop
                let span = next.at.timeIntervalSince(last.at)
                fraction = span > 0 ? now.timeIntervalSince(last.at) / span : 1
            } else {
                guard next.stop > 0 else {
                    var waiting = bus(vehicle, at: route.stops[0].coordinate, heading: nil, next: 0, calls: calls, route: route, predictions: predictions)
                    waiting.waiting = true
                    return waiting
                }
                from = next.stop - 1
                // As long as the next stretch takes, by its own times.
                let following = calls.dropFirst(nextCall + 1).first
                let hop = following.map { $0.at.timeIntervalSince(next.at) / Double(max(1, $0.stop - next.stop)) } ?? 75
                let span = min(max(hop, 30), 240)
                fraction = 1 - min(1, next.at.timeIntervalSince(now) / span)
            }
            let point = route.point(between: from, and: next.stop, fraction: fraction)
            return bus(vehicle, at: point.coordinate, heading: point.heading, next: next.stop, calls: calls, route: route, predictions: predictions)
        }
        .sorted { $0.nextStop > $1.nextStop }
    }

    private static func bus(_ vehicle: String, at coordinate: Coordinate, heading: Double?, next: Int,
                            calls: [(stop: Int, at: Date)], route: Route, predictions: [Prediction]) -> Bus {
        Bus(id: vehicle, coordinate: coordinate, heading: heading, destination: predictions.first?.destination ?? "",
            nextStop: next, due: Dictionary(calls.filter { $0.stop >= next }.map { (route.stops[$0.stop].id, $0.at) },
                                            uniquingKeysWith: { a, _ in a }))
    }

    // MARK: DTOs

    private struct RouteDTO: Decodable {
        var lineId: String
        var direction: String?
        var lineStrings: [String]
        var stopPointSequences: [Sequence]

        struct Sequence: Decodable {
            var direction: String?
            var stopPoint: [StopDTO]
        }
        struct StopDTO: Decodable {
            var id: String
            var name: String
            var stopLetter: String?
            var lat: Double?
            var lon: Double?
        }
    }

    private struct ArrivalDTO: Decodable {
        var vehicleId: String?
        var naptanId: String?
        var direction: String?
        var destinationName: String?
        var expectedArrival: String?
    }
}

/// Points and distances along a drawn line, in metres. Flat-earth maths, fine across a city.
enum Geometry {
    /// Each point's distance along `path`, taken in order so a route that comes back
    /// the same way doesn't put a later stop on the earlier pass; and how far off the
    /// worst one sits.
    static func snap(_ points: [Coordinate], to path: [Coordinate]) -> (along: [Double], error: Double) {
        guard path.count > 1, let origin = path.first else { return ([], .infinity) }
        let xy = path.map { metres($0, origin: origin) }
        var cumulative = [0.0]
        for i in 1..<xy.count { cumulative.append(cumulative[i - 1] + hypot(xy[i].x - xy[i - 1].x, xy[i].y - xy[i - 1].y)) }
        var along: [Double] = []
        var worst = 0.0
        var segment = 1
        for point in points {
            let p = metres(point, origin: origin)
            var best = (distance: Double.infinity, along: 0.0, segment: segment)
            // Look ahead from the last stop, a stretch at a time, rather than the whole route.
            for i in segment..<xy.count {
                let (a, b) = (xy[i - 1], xy[i])
                let (dx, dy) = (b.x - a.x, b.y - a.y)
                let length2 = dx * dx + dy * dy
                let t = length2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0
                let distance = hypot(a.x + t * dx - p.x, a.y + t * dy - p.y)
                if distance < best.distance - 0.5 { best = (distance, cumulative[i - 1] + t * length2.squareRoot(), i) }
                // Well past the stop and moving away: stop looking.
                if best.distance < 30, cumulative[i - 1] - best.along > 1500 { break }
            }
            along.append(best.along)
            worst = max(worst, best.distance)
            segment = best.segment
        }
        return (along, worst)
    }

    /// The point `distance` metres along `path`, and which way the path runs there.
    static func point(at distance: Double, on path: [Coordinate]) -> (coordinate: Coordinate, heading: Double?) {
        guard let origin = path.first else { return (Coordinate(latitude: 0, longitude: 0), nil) }
        var previous = origin
        var travelled = 0.0
        for next in path.dropFirst() {
            // Measured as `snap` measures, so distances from it land in the same place.
            let (a, b) = (metres(previous, origin: origin), metres(next, origin: origin))
            let length = hypot(b.x - a.x, b.y - a.y)
            if travelled + length >= distance, length > 0 {
                let f = (distance - travelled) / length
                return (Coordinate(latitude: previous.latitude + (next.latitude - previous.latitude) * f,
                                   longitude: previous.longitude + (next.longitude - previous.longitude) * f),
                        bearing(from: previous, to: next))
            }
            travelled += length
            previous = next
        }
        let last = path.suffix(2)
        return (previous, last.count == 2 ? bearing(from: last.first!, to: last.last!) : nil)
    }

    /// Degrees from north.
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let p = metres(b, origin: a)
        let degrees = atan2(p.x, p.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func metres(_ c: Coordinate, origin: Coordinate) -> (x: Double, y: Double) {
        let k = cos(origin.latitude * .pi / 180)
        return ((c.longitude - origin.longitude) * 111_320 * k, (c.latitude - origin.latitude) * 110_540)
    }
}
