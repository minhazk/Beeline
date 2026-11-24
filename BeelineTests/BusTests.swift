import Foundation
import Testing
@testable import Beeline

/// Live London buses: the route from TfL, each bus placed between the stops it's
/// passed and is due at, and which way along the line a stop means. Recorded on
/// the 25 (Hainault Street to Holborn Circus) at 13:26 on 10 November 2026.
@MainActor
struct BusTests {
    static let recordedAt = Time.iso("2026-11-10T13:26:04Z")!

    static func routes() throws -> (outbound: TfLBuses.Route, inbound: TfLBuses.Route) {
        let outbound = try TfLBuses.parseRoutes(ProviderParsingTests.fixture("tfl-bus-25-outbound"))
        let inbound = try TfLBuses.parseRoutes(ProviderParsingTests.fixture("tfl-bus-25-inbound"))
        return (try #require(outbound.first), try #require(inbound.first))
    }

    static func predictions() throws -> [TfLBuses.Prediction] {
        try TfLBuses.parseArrivals(ProviderParsingTests.fixture("tfl-bus-25-arrivals"))
    }

    @Test func aRouteIsItsStopsInOrderOnTheRoad() throws {
        let route = try Self.routes().outbound
        #expect(route.lineID == "25")
        #expect(route.direction == "outbound")
        #expect(route.stops.count == 50)
        #expect(route.stops.first?.name == "Hainault Street")
        #expect(route.stops.first?.letter == "V")
        // TfL's "->W" is a direction, not a letter on the flag.
        #expect(route.stops[10].letter == nil)
        #expect(route.stops.last?.name == "Holborn Circus")
        // Every stop lands on the drawn road, in order.
        let along = try #require(route.stopAlong)
        #expect(along.count == route.stops.count)
        #expect(zip(along, along.dropFirst()).allSatisfy { $0 < $1 })
        #expect(route.path.count > 100)
    }

    @Test func predictionsAreEachBusAtEachStop() throws {
        let predictions = try Self.predictions()
        #expect(predictions.count == 402)
        #expect(Set(predictions.map(\.direction)) == ["outbound", "inbound"])
        #expect(predictions.allSatisfy { !$0.vehicleID.isEmpty && $0.stopID.hasPrefix("490") })
    }

    @Test func busesSitOnTheRoadBetweenTheirStops() throws {
        let route = try Self.routes().outbound
        let buses = TfLBuses.buses(on: route, from: try Self.predictions(), at: Self.recordedAt)
        #expect(buses.count >= 10)
        let along = try #require(route.stopAlong)
        for bus in buses {
            let progress = try #require(PathProgress.locate(bus.coordinate, on: route.path))
            #expect(progress.distanceFromPath < 25, "\(bus.id) is off the road")
            guard bus.nextStop > 0 else { continue }
            // Between the stop before its next one and that next one.
            #expect(progress.distanceAlong >= along[bus.nextStop - 1] - 25 && progress.distanceAlong <= along[bus.nextStop] + 25, "\(bus.id)")
            #expect(bus.due[route.stops[bus.nextStop].id] != nil)
        }
        // Each bus once; none going the other way.
        #expect(Set(buses.map(\.id)).count == buses.count)
        #expect(buses.allSatisfy { $0.destination.contains("Holborn") })
    }

    /// Three stops 500 m apart on a straight road.
    static func line() -> TfLBuses.Route {
        let stops = (0..<3).map { i in
            TfLBuses.Route.Stop(id: "s\(i)", name: "Stop \(i)", letter: nil,
                                coordinate: Coordinate(latitude: 51.5, longitude: -0.1 + Double(i) * 0.0072))
        }
        let path = stops.map(\.coordinate)
        return TfLBuses.Route(lineID: "1", direction: "outbound", stops: stops, path: path,
                              stopAlong: Geometry.snap(path, to: path).along)
    }

    static func prediction(_ stop: Int, in seconds: TimeInterval, from now: Date) -> TfLBuses.Prediction {
        TfLBuses.Prediction(vehicleID: "LX11", stopID: "s\(stop)", direction: "outbound", destination: "Stop 2",
                            expected: now.addingTimeInterval(seconds))
    }

    @Test func aBusMovesOnBetweenAnswers() throws {
        let route = Self.line()
        let now = Self.recordedAt
        let along = try #require(route.stopAlong)
        // Due at stop 1 in 30 s and stop 2 90 s after that: two thirds of the way to stop 1.
        let first = [Self.prediction(1, in: 30, from: now), Self.prediction(2, in: 120, from: now)]
        let bus = try #require(TfLBuses.buses(on: route, from: first, at: now).first)
        #expect(bus.nextStop == 1)
        let at = try #require(PathProgress.locate(bus.coordinate, on: route.path)).distanceAlong
        #expect(abs(at - along[1] * 2 / 3) < 10)
        #expect(abs((bus.heading ?? 0) - 90) < 2, "heading east")
        // A minute later it's passed stop 1: placed by the two times either side.
        let later = try #require(TfLBuses.buses(on: route, from: first, at: now.addingTimeInterval(75)).first)
        #expect(later.nextStop == 2)
        let laterAt = try #require(PathProgress.locate(later.coordinate, on: route.path)).distanceAlong
        #expect(abs(laterAt - (along[1] + (along[2] - along[1]) / 2)) < 10)
        // Past its last stop, it's gone.
        #expect(TfLBuses.buses(on: route, from: first, at: now.addingTimeInterval(200)).isEmpty)
    }

    @Test func aBusStillToStartWaitsAtTheFirstStop() throws {
        let route = Self.line()
        let now = Self.recordedAt
        let waiting = try #require(TfLBuses.buses(on: route, from: [Self.prediction(0, in: 600, from: now), Self.prediction(2, in: 800, from: now)], at: now).first)
        #expect(waiting.waiting)
        #expect(waiting.coordinate == route.stops[0].coordinate)
        #expect(waiting.due["s2"] == now.addingTimeInterval(800))
        #expect(TfLBuses.buses(on: route, from: [Self.prediction(1, in: 40, from: now)], at: now).first?.waiting == false)
    }

    @Test func aStopPicksTheWayTheBusGoes() throws {
        let (outbound, inbound) = try Self.routes()
        let routes = [outbound, inbound]
        // A ride from Shrewsbury Road to Queen Mary goes west, so outbound.
        let west = BusWatch(lineID: "25", from: outbound.stops[10].coordinate, to: outbound.stops[30].coordinate)
        let ride = try #require(BusWatch.resolve(west, in: routes))
        #expect(ride.route.direction == "outbound")
        #expect(ride.stop == 10)
        #expect(ride.end == 30)
        // The same stops the other way round are the other side of the road.
        let east = BusWatch(lineID: "25", from: inbound.stops[18].coordinate, to: inbound.stops[38].coordinate)
        #expect(BusWatch.resolve(east, in: routes)?.route.direction == "inbound")
        // From a stop alone, its own side wins, and the destination breaks a tie.
        #expect(BusWatch.resolve(BusWatch(lineID: "25", from: inbound.stops[38].coordinate, to: nil), in: routes)?.route.direction == "inbound")
        #expect(BusWatch.resolve(BusWatch(lineID: "25", from: outbound.stops[10].coordinate, to: nil), in: routes)?.route.direction == "outbound")
        let between = Coordinate(latitude: (outbound.stops[10].coordinate.latitude + inbound.stops[38].coordinate.latitude) / 2,
                                 longitude: (outbound.stops[10].coordinate.longitude + inbound.stops[38].coordinate.longitude) / 2)
        #expect(BusWatch.resolve(BusWatch(lineID: "25", from: between, to: nil, headsign: "Holborn Circus"), in: routes)?.route.direction == "outbound")
        #expect(BusWatch.resolve(BusWatch(lineID: "25", from: between, to: nil, headsign: "Hainault Street"), in: routes)?.route.direction == "inbound")
        // A bus station's stands for both ways sit together; "City of London" is west, through City Thameslink,
        // even from the eastbound stand.
        let eastStand = try #require(inbound.stops.first { $0.name == "Stratford Bus Station" && $0.letter == "AP" })
        #expect(BusWatch.resolve(BusWatch(lineID: "25", from: eastStand.coordinate, to: nil, headsign: "City of London"), in: routes)?.route.direction == "outbound")
        let westStand = try #require(outbound.stops.first { $0.name == "Stratford Bus Station" })
        #expect(BusWatch.resolve(BusWatch(lineID: "25", from: westStand.coordinate, to: nil, headsign: "Ilford"), in: routes)?.route.direction == "inbound")
    }

    @Test func busLinesInTfLsForm() {
        #expect(TfLBuses.lineID("25") == "25")
        #expect(TfLBuses.lineID("N25") == "n25")
        #expect(TfLBuses.lineID("SL6") == "sl6")
        #expect(TfLBuses.lineID("Northern") == nil)
        #expect(BusWatch(leg: Leg(mode: .tube, line: "Northern", fromName: "A", toName: "B", departure: .now, arrival: .now,
                                  path: [Self.line().stops[0].coordinate])) == nil)
    }

    // MARK: Go on live times

    static func approach(_ vehicle: String, at stop: Date, off: Date?) -> LiveBusStore.Approach {
        var due = ["s1": stop]
        if let off { due["s2"] = off }
        let bus = TfLBuses.Bus(id: vehicle, coordinate: line().stops[0].coordinate, heading: 90, destination: "Stop 2",
                               nextStop: 1, due: due)
        return LiveBusStore.Approach(bus: bus, due: stop, stopsAway: 0, near: "Stop 1")
    }

    static func ride(leaving: Date) -> Leg {
        Leg(mode: .bus, line: "241", fromName: "Stop 1", toName: "Stop 2", departure: leaving,
            arrival: leaving.addingTimeInterval(600), path: line().stops.dropFirst().map(\.coordinate))
    }

    @Test func goTakesTheRealBusNotTheTimetablesOne() throws {
        let t = Self.recordedAt
        let ride = Self.ride(leaving: t.addingTimeInterval(600))
        let board = { (buses: [LiveBusStore.Approach], preferred: String?) in
            LiveBusStore.board(for: ride, approaching: buses, route: Self.line(), stop: 1, end: 2, timetable: nil, preferred: preferred)
        }
        // A bus three minutes before the timetable's counts as yours; when it gets you off comes from TfL too.
        let early = [Self.approach("A", at: t.addingTimeInterval(420), off: t.addingTimeInterval(900)),
                     Self.approach("B", at: t.addingTimeInterval(1380), off: nil)]
        let near = try #require(board(early, nil))
        #expect(near.planned?.id == "tfl-A")
        #expect(near.planned?.arrivalThere == t.addingTimeInterval(900))
        #expect(near.planned?.isRealtime == true)
        #expect(near.nextAfterPlanned?.id == "tfl-B")
        // TfL has no time for B at the stop off yet: it takes as long as A does, not none at all.
        #expect(near.departures.last?.arrivalThere == t.addingTimeInterval(1380 + 480))
        #expect(near.arrivalDifference(try #require(near.nextAfterPlanned)) == 960)
        // The timetabled one has gone (or never ran): the next real one is yours.
        let gone = [Self.approach("A", at: t.addingTimeInterval(300), off: nil),
                    Self.approach("B", at: t.addingTimeInterval(1380), off: nil)]
        #expect(board(gone, nil)?.planned?.id == "tfl-B")
        // Once picked, it stays yours while it's coming, even if another drifts nearer the timetable.
        let drifted = [Self.approach("A", at: t.addingTimeInterval(400), off: nil),
                       Self.approach("B", at: t.addingTimeInterval(640), off: nil)]
        #expect(board(drifted, "A")?.planned?.id == "tfl-A")
        #expect(board(drifted, nil)?.planned?.id == "tfl-B")
        // Nothing near enough: the timetable stands.
        #expect(board([Self.approach("A", at: t.addingTimeInterval(60), off: nil)], nil) == nil)
    }

    @Test func missingItGoesByTheLiveTime() {
        let t = Self.recordedAt
        let ride = Self.ride(leaving: t)
        let atStop = ride.start
        // The timetable's bus was a minute and a half ago, but yours is still coming.
        #expect(TripProgress.missed(ride, now: t.addingTimeInterval(90), location: atStop))
        #expect(!TripProgress.missed(ride, now: t.addingTimeInterval(90), location: atStop, departure: t.addingTimeInterval(300)))
    }
}
