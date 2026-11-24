import Foundation
import Observation
import SwiftUI

/// A bus line seen from one stop: the ride you're taking (from where you get on to
/// where you get off), or a line leaving a stop near you.
struct BusWatch: Hashable, Sendable {
    /// TfL's id for the line ("25", "n25").
    var lineID: String
    var color: RGB?
    var from: Coordinate
    var to: Coordinate?
    var headsign: String?

    init(lineID: String, color: RGB? = nil, from: Coordinate, to: Coordinate?, headsign: String? = nil) {
        (self.lineID, self.color, self.from, self.to, self.headsign) = (lineID, color, from, to, headsign)
    }

    init?(leg: Leg) {
        guard leg.mode == .bus, let id = TfLBuses.lineID(leg.line), let start = leg.start else { return nil }
        self.init(lineID: id, color: leg.lineColor, from: start, to: leg.end, headsign: leg.headsign)
    }

    init?(nearby line: NearbyLine) {
        guard line.mode == .bus, let id = TfLBuses.lineID(line.line) else { return nil }
        self.init(lineID: id, color: line.lineColor, from: line.stopCoordinate, to: nil,
                  headsign: line.headsign.isEmpty ? nil : line.headsign)
    }

    /// Which way along which route the watch means, and the stops it's from and to.
    static func resolve(_ watch: BusWatch, in routes: [TfLBuses.Route]) -> (route: TfLBuses.Route, stop: Int, end: Int?)? {
        let wanted = watch.headsign.map(words) ?? []
        return routes.compactMap { route -> (TfLBuses.Route, Int, Int?, Double)? in
            guard let stop = route.nearestStop(to: watch.from) else { return nil }
            var score = stop.distance
            var end: Int?
            if let to = watch.to {
                // It has to call where you get off, after where you get on.
                guard let found = route.nearestStop(to: to, within: 200, after: stop.index) else { return nil }
                end = found.index
                score += found.distance
            } else if !wanted.isEmpty {
                // Stops either side of the road, or a bus station's stands, sit close together;
                // where it's going tells them apart: somewhere on the way, not just the end
                // ("City of London" is the 25 west, through City Thameslink).
                let ahead = route.stops[(stop.index + 1)...].reduce(into: Set<String>()) { $0.formUnion(words($1.name)) }
                if !wanted.isDisjoint(with: ahead) { score -= 150 }
            }
            // A stop at the very end is where it stops, not where it leaves from.
            if stop.index == route.stops.count - 1 { score += 200 }
            return (route, stop.index, end, score)
        }
        .min { $0.3 < $1.3 }
        .map { ($0.0, $0.1, $0.2) }
    }

    /// The words in a place name that say where it is, without the ones every stop has.
    static func words(_ name: String) -> Set<String> {
        let common: Set<String> = ["the", "and", "for", "via", "london", "station", "stn", "bus", "road", "street",
                                   "lane", "avenue", "stop", "centre", "center", "park", "high", "upper", "lower",
                                   "north", "south", "east", "west", "new"]
        return Set(name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !common.contains($0) })
    }
}

/// Live buses for the line on the map: its route, and where each bus is, asked of
/// TfL every 30 seconds and moved along between times.
@MainActor @Observable
final class LiveBusStore {
    private(set) var watch: BusWatch?
    private(set) var route: TfLBuses.Route?
    /// The stop you're watching from, and where you'd get off.
    private(set) var stopIndex: Int?
    private(set) var endIndex: Int?
    private(set) var predictions: [TfLBuses.Prediction] = []
    private(set) var updatedAt: Date?
    private(set) var problem: String?
    private(set) var now = Date.now

    /// Both directions of each line asked about, for as long as the app is open.
    private var routes: [String: [TfLBuses.Route]] = [:]

    static let refreshEvery: TimeInterval = 30

    var buses: [TfLBuses.Bus] {
        guard let route else { return [] }
        return TfLBuses.buses(on: route, from: predictions, at: now)
    }

    struct Approach: Identifiable, Hashable {
        var bus: TfLBuses.Bus
        var due: Date
        /// 0 when your stop is its next.
        var stopsAway: Int
        /// The stop it's coming up to.
        var near: String

        var id: String { bus.id }
    }

    /// The buses to draw: every one on the road, and of those still to start, only
    /// the one about to (the rest would pile up at the first stop).
    var drawn: [TfLBuses.Bus] {
        guard let route else { return [] }
        let all = buses
        let first = route.stops[0].id
        let leaving = all.filter(\.waiting).min { ($0.due[first] ?? .distantFuture) < ($1.due[first] ?? .distantFuture) }
        return all.filter { !$0.waiting || ($0.id == leaving?.id && ($0.due[first] ?? .distantFuture) < now.addingTimeInterval(10 * 60)) }
    }

    /// Buses still to reach your stop, soonest first.
    var approaching: [Approach] {
        guard let route, let stopIndex else { return [] }
        let stopID = route.stops[stopIndex].id
        return buses.compactMap { bus in
            guard bus.nextStop <= stopIndex, let due = bus.due[stopID], due > now.addingTimeInterval(-20) else { return nil }
            return Approach(bus: bus, due: due, stopsAway: stopIndex - bus.nextStop, near: route.stops[bus.nextStop].name)
        }
        .sorted { $0.due < $1.due }
    }

    /// A ride's departure board from TfL's live times, for the bus line on show: the
    /// buses still to reach your stop, with when each gets you off. Nil when this
    /// isn't the line being watched or TfL has no bus near the timetable's.
    func board(for ride: Leg, timetable: DepartureBoard?, preferred: String? = nil) -> DepartureBoard? {
        guard let watch, watch == BusWatch(leg: ride), updatedAt != nil, let route, let stopIndex else { return nil }
        return Self.board(for: ride, approaching: approaching, route: route, stop: stopIndex, end: endIndex,
                          timetable: timetable, preferred: preferred)
    }

    /// The board from buses on the way. "Yours" is the bus you've been told about if
    /// it's still coming, else the one nearest the timetable's time (or the first
    /// after it, when the timetabled one has gone or never ran).
    static func board(for ride: Leg, approaching: [Approach], route: TfLBuses.Route, stop: Int, end: Int?,
                      timetable: DepartureBoard?, preferred: String?) -> DepartureBoard? {
        let stopOff = end.map { route.stops[$0].id }
        // TfL only looks about half an hour ahead, so a later bus may have no time at
        // your stop off yet: give it as long as the ride takes on one that has.
        let rideTime = stopOff.flatMap { off in
            approaching.lazy.compactMap { a in a.bus.due[off].map { $0.timeIntervalSince(a.due) } }.first
        } ?? ride.duration
        let departures = approaching.map { approach in
            Departure(id: "tfl-\(approach.bus.id)", line: ride.line ?? "", mode: .bus, lineColor: ride.lineColor,
                      headsign: approach.bus.destination, stopName: route.stops[stop].name,
                      stopCoordinate: route.stops[stop].coordinate, scheduled: approach.due, expected: approach.due,
                      isRealtime: true, isCancelled: false, platform: route.stops[stop].letter,
                      arrivalThere: stopOff.flatMap { approach.bus.due[$0] } ?? approach.due.addingTimeInterval(rideTime))
        }
        let target = timetable?.planned?.expected ?? ride.departure
        let yours = preferred.flatMap { id in departures.first { $0.id == "tfl-\(id)" } }
            ?? departures.filter { $0.expected >= target.addingTimeInterval(-4 * 60) }
                .min { abs($0.expected.timeIntervalSince(target)) < abs($1.expected.timeIntervalSince(target)) }
        guard let yours else { return nil }
        return DepartureBoard(stopName: route.stops[stop].name, departures: departures, plannedID: yours.id,
                              alerts: timetable?.alerts ?? [])
    }

    /// When a bus reaches where you get off, if TfL has a time for it there.
    func arrival(of bus: TfLBuses.Bus) -> Date? {
        guard let route, let endIndex else { return nil }
        return bus.due[route.stops[endIndex].id]
    }

    /// Runs while the map shows `watch`: finds the route, then keeps the buses fresh.
    /// Cancelling the task (the map moving on) stops it.
    func run(_ watch: BusWatch, appKey: String?) async {
        #if DEBUG
        if Demo.offline { return }
        #endif
        if self.watch != watch {
            self.watch = watch
            route = nil
            stopIndex = nil
            endIndex = nil
            predictions = []
            updatedAt = nil
        }
        problem = nil
        guard await resolve(watch, appKey: appKey) else { return }
        while !Task.isCancelled, self.watch == watch {
            if updatedAt.map({ Date.now.timeIntervalSince($0) >= Self.refreshEvery }) ?? true {
                await refresh(watch, appKey: appKey)
            }
            withAnimation(.linear(duration: 2)) { now = .now }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func clear() {
        watch = nil
        route = nil
        stopIndex = nil
        endIndex = nil
        predictions = []
        updatedAt = nil
        problem = nil
    }

    private func resolve(_ watch: BusWatch, appKey: String?) async -> Bool {
        if route != nil { return true }
        if routes[watch.lineID] == nil {
            // Both directions, once per line: which one you want depends on the stop.
            async let outbound = Self.fetchRoutes(watch.lineID, direction: "outbound", appKey: appKey)
            async let inbound = Self.fetchRoutes(watch.lineID, direction: "inbound", appKey: appKey)
            let found = (await outbound) + (await inbound)
            guard !Task.isCancelled else { return false }
            if found.isEmpty {
                problem = "TfL has no live times for this line."
                return false
            }
            routes[watch.lineID] = found
        }
        guard let match = BusWatch.resolve(watch, in: routes[watch.lineID] ?? []) else {
            problem = "Couldn't find this stop on TfL's route for the line."
            return false
        }
        route = match.route
        stopIndex = match.stop
        endIndex = match.end
        return true
    }

    private static func fetchRoutes(_ lineID: String, direction: String, appKey: String?) async -> [TfLBuses.Route] {
        guard let data = try? await HTTP.data(for: TfLBuses.routeRequest(lineID, direction: direction, appKey: appKey)) else { return [] }
        return (try? TfLBuses.parseRoutes(data)) ?? []
    }

    private func refresh(_ watch: BusWatch, appKey: String?) async {
        do {
            let fresh = try TfLBuses.parseArrivals(try await HTTP.data(for: TfLBuses.arrivalsRequest(watch.lineID, appKey: appKey)))
            guard !Task.isCancelled, self.watch == watch else { return }
            // Keep times already passed from the last answer, so a bus moves on from the
            // stop it just left rather than jumping back to guessing.
            let current = Set(fresh.map { "\($0.vehicleID)|\($0.stopID)" })
            let passed = predictions.filter { $0.expected <= .now && $0.expected > .now.addingTimeInterval(-300)
                && !current.contains("\($0.vehicleID)|\($0.stopID)") }
            predictions = fresh + passed
            updatedAt = .now
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            // Try again on the next tick rather than waiting a whole refresh.
            updatedAt = Date.now.addingTimeInterval(-Self.refreshEvery + 10)
            if predictions.isEmpty { problem = "Couldn't reach TfL for live buses." }
        }
    }
}
