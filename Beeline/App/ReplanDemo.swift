#if DEBUG
import Foundation

/// Re-planning on screen without the network (`-demo -demoReplan offer|wait|early`, Debug only):
/// The sample Bakerloo trip with a 277 at the end, re-timed to now, early onto the Bakerloo (the
/// 06:26 instead of the 06:41). Go runs as it does for real, on canned boards and a canned
/// planner answer. Nothing is asked of any source.
@MainActor
enum ReplanDemo {
    static let scenario = Demo.replan ?? "offer"
    /// The trip's clock: "06:27:00" is the moment the demo opens.
    static let base = Date.now.addingTimeInterval(-(6 * 3600 + 27 * 60))
    static func at(_ clock: String) -> Date {
        let p = clock.split(separator: ":").compactMap { Double($0) }
        return base.addingTimeInterval(p[0] * 3600 + p[1] * 60 + (p.count > 2 ? p[2] : 0))
    }

    /// Norfolk Square, a public garden by Paddington.
    static let start = Coordinate(latitude: 51.5154, longitude: -0.1739)
    static let paddington = Coordinate(latitude: 51.5154, longitude: -0.1755)
    static let bakerStreet = Coordinate(latitude: 51.5226, longitude: -0.1571)
    static let jubileePlatform = Coordinate(latitude: 51.5230, longitude: -0.1570)
    static let canaryWharf = Coordinate(latitude: 51.5035, longitude: -0.0187)
    static let busStop = Coordinate(latitude: 51.5040, longitude: -0.0175)
    static let crossharbour = Coordinate(latitude: 51.4957, longitude: -0.0144)
    static let island = Coordinate(latitude: 51.4950, longitude: -0.0150)
    static let heronQuays = Coordinate(latitude: 51.5027, longitude: -0.0215)

    static let destination = Place(name: scenario == "early" ? "One Canada Square" : "Crossharbour", coordinate: scenario == "early" ? canaryWharf : island)
    static let query = JourneyQuery(origin: Place(name: "Norfolk Square", coordinate: start), destination: destination, time: .leaveNow)

    static let journey: Journey = {
        let walk = Leg(mode: .walk, fromName: "Norfolk Square", toName: "Paddington", departure: at("06:34"), arrival: at("06:39"),
                       distanceMeters: 300, path: [start, paddington])
        let bakerloo = Leg(mode: .tube, line: "Bakerloo", lineColor: RGB(hex: "B36305"), headsign: "Elephant & Castle", fromName: "Paddington",
                           toName: "Baker Street", departure: at("06:41"), arrival: at("06:49"), stopCount: 3, path: [paddington, bakerStreet], platform: "3")
        let change = Leg(mode: .walk, fromName: "Baker Street", toName: "Baker Street", departure: at("06:49"), arrival: at("06:52"),
                         path: [bakerStreet, jubileePlatform])
        let jubilee = Leg(mode: .tube, line: "Jubilee", lineColor: RGB(hex: "A0A5A9"), headsign: "Stratford", fromName: "Baker Street",
                          toName: "Canary Wharf", departure: at("06:55"), arrival: at("07:15"), stopCount: 9, path: [jubileePlatform, canaryWharf])
        if scenario == "early" {
            let last = Leg(mode: .walk, fromName: "Canary Wharf", toName: "One Canada Square", departure: at("07:15"), arrival: at("07:20"), path: [canaryWharf, canaryWharf])
            return Journey(departure: at("06:34"), arrival: at("07:20"), legs: [walk, bakerloo, change, jubilee, last],
                           sources: [SourceTag(provider: .tfl, variant: "Fastest")])
        }
        let toStop = Leg(mode: .walk, fromName: "Canary Wharf", toName: "Canary Wharf Station", departure: at("07:15"), arrival: at("07:17"),
                         path: [canaryWharf, busStop])
        let bus = Leg(mode: .bus, line: "277", lineColor: RGB(hex: "DC241F"), headsign: "Crossharbour", fromName: "Canary Wharf Station",
                      toName: "Crossharbour", departure: at("07:20"), arrival: at("07:30"), stopCount: 6, path: [busStop, crossharbour], platform: "C")
        let last = Leg(mode: .walk, fromName: "Crossharbour", toName: "Crossharbour", departure: at("07:30"), arrival: at("07:34"),
                       path: [crossharbour, island])
        return Journey(departure: at("06:34"), arrival: at("07:34"), legs: [walk, bakerloo, change, jubilee, toStop, bus, last],
                       sources: [SourceTag(provider: .tfl, variant: "Fastest")])
    }()

    static func board(_ leg: Leg, at times: [String], run: Double, planned: String) -> DepartureBoard {
        let departures = times.map { time in
            Departure(id: "\(leg.line!)-\(time)", line: leg.line!, mode: leg.mode, lineColor: leg.lineColor, headsign: leg.headsign ?? "",
                      stopName: leg.fromName, stopCoordinate: leg.start!, scheduled: at(time), expected: at(time), isRealtime: true,
                      isCancelled: false, platform: leg.platform, arrivalThere: at(time).addingTimeInterval(run * 60))
        }
        return DepartureBoard(stopName: leg.fromName, departures: departures, plannedID: "\(leg.line!)-\(planned)")
    }

    static let boards: [UUID: DepartureBoard] = {
        let legs = journey.legs
        var boards = [
            legs[1].id: board(legs[1], at: ["06:22", "06:26", "06:30", "06:34", "06:37", "06:41", "06:44", "06:48", "06:52"], run: 8, planned: "06:41"),
            legs[3].id: board(legs[3], at: ["06:35", "06:39", "06:43", "06:47", "06:51", "06:55", "06:59", "07:03", "07:07"], run: 20, planned: "06:55"),
        ]
        if legs.count > 5 { boards[legs[5].id] = board(legs[5], at: ["07:00", "07:20", "07:40", "08:00"], run: 10, planned: "07:20") }
        return boards
    }()

    /// The planner's answer from Baker Street: the Jubilee then the DLR, or (for "wait")
    /// only ways that don't beat the 277 by enough.
    static var candidates: [Journey] {
        func way(_ rides: [Leg], start: String, end: String) -> Journey {
            Journey(departure: at(start), arrival: at(end), legs: rides, sources: [SourceTag(provider: .transitous, variant: "Fastest")])
        }
        let jubilee = Leg(mode: .tube, line: "Jubilee", lineColor: RGB(hex: "A0A5A9"), headsign: "Stratford", fromName: "Baker Street",
                          toName: "Canary Wharf", departure: at("06:39"), arrival: at("06:59"), path: [jubileePlatform, canaryWharf])
        let walk = Leg(mode: .walk, fromName: "Canary Wharf", toName: "Heron Quays", departure: at("06:59"), arrival: at("07:03"),
                       distanceMeters: 300, path: [canaryWharf, heronQuays])
        let dlr = Leg(mode: .dlr, line: "DLR", lineColor: RGB(hex: "00A4A7"), headsign: "Lewisham", fromName: "Heron Quays",
                      toName: "Crossharbour", departure: at("07:05"), arrival: at("07:10"), path: [heronQuays, crossharbour])
        let end = Leg(mode: .walk, fromName: "Crossharbour", toName: "Crossharbour", departure: at("07:10"), arrival: at("07:13"), path: [crossharbour, island])
        let slowDLR = Leg(mode: .dlr, line: "DLR", lineColor: RGB(hex: "00A4A7"), headsign: "Lewisham", fromName: "Heron Quays",
                          toName: "Crossharbour", departure: at("07:23"), arrival: at("07:28"), path: [heronQuays, crossharbour])
        if scenario == "wait" {
            var late = end
            (late.departure, late.arrival) = (at("07:28"), at("07:31"))
            return [way([jubilee, walk, slowDLR, late], start: "06:34", end: "07:31")]
        }
        return [way([jubilee, walk, dlr, end], start: "06:34", end: "07:13")]
    }

    /// The planner's answer to Go's re-plan, straight away and from nowhere: Go's own triggers,
    /// judging and offer run on it as they would on a real one.
    static let search: ReplanSearch.Search = { _, _ in
        ReplanAnswer(journeys: candidates, answered: true, usedGoogle: false)
    }
}
#endif
