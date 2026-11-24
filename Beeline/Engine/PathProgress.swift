import Foundation

/// Where someone is along a path: how far they've come, how far is left, and
/// how far they've strayed from it. Flat-earth maths, fine over a walk.
struct PathProgress: Equatable, Sendable {
    var distanceFromPath: Double
    var distanceAlong: Double
    var remaining: Double

    static func locate(_ point: Coordinate, on path: [Coordinate]) -> PathProgress? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else {
            let d = point.distance(to: first)
            return PathProgress(distanceFromPath: d, distanceAlong: 0, remaining: 0)
        }
        let project = Projection(origin: point)
        let xy = path.map(project.metres)
        var best = (distance: Double.infinity, along: 0.0)
        var travelled = 0.0
        for i in 1..<xy.count {
            let (a, b) = (xy[i - 1], xy[i])
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let length = (dx * dx + dy * dy).squareRoot()
            // The point itself sits at the origin.
            let t = length > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / (length * length))) : 0
            let (px, py) = (a.x + t * dx, a.y + t * dy)
            let distance = (px * px + py * py).squareRoot()
            if distance < best.distance { best = (distance, travelled + t * length) }
            travelled += length
        }
        return PathProgress(distanceFromPath: best.distance, distanceAlong: best.along, remaining: max(0, travelled - best.along))
    }

    /// The point `metres` along a path, clamped to its ends.
    static func point(along metres: Double, on path: [Coordinate]) -> Coordinate? {
        guard let first = path.first else { return nil }
        var left = max(0, metres)
        for (a, b) in zip(path, path.dropFirst()) {
            let piece = length(of: [a, b])
            if piece > 0, left <= piece {
                let t = left / piece
                return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                  longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            left -= piece
        }
        return path.last ?? first
    }

    static func length(of path: [Coordinate]) -> Double {
        guard let first = path.first else { return 0 }
        let project = Projection(origin: first)
        return zip(path, path.dropFirst()).reduce(0) { total, pair in
            let (a, b) = (project.metres(pair.0), project.metres(pair.1))
            return total + ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
    }

    /// Equirectangular metres around an origin.
    private struct Projection {
        var origin: Coordinate

        func metres(_ c: Coordinate) -> (x: Double, y: Double) {
            let k = cos(origin.latitude * .pi / 180)
            return ((c.longitude - origin.longitude) * 111_320 * k, (c.latitude - origin.latitude) * 110_540)
        }
    }
}

/// A walking route with turn-by-turn steps (from MapKit, or a source's bare path).
struct WalkRoute: Hashable, Sendable {
    struct Step: Hashable, Sendable {
        /// "Turn right onto Pentonville Road". Describes the turn at the step's start.
        var instruction: String
        var distance: Double
    }

    var path: [Coordinate]
    var steps: [Step]
    var distance: Double
    var expectedTime: TimeInterval

    /// What to do next from a point along the route, and how far ahead it is.
    func guidance(at along: Double) -> (instruction: String?, distance: Double) {
        let total = steps.reduce(0) { $0 + $1.distance }
        guard total > 0, !steps.isEmpty else { return (nil, max(0, distance - along)) }
        // Step lengths from MapKit don't quite sum to the drawn path.
        let scale = distance / total
        var end = 0.0
        for (index, step) in steps.enumerated() {
            end += step.distance * scale
            if along < end - 5 {
                let next = steps.dropFirst(index + 1).first { !$0.instruction.isEmpty }
                return (next?.instruction, max(0, end - along))
            }
        }
        return (nil, max(0, distance - along))
    }
}

/// How a walk lines up with the vehicle at the end of it.
struct Connection: Equatable, Sendable {
    enum Verdict: Equatable, Sendable { case comfortable, tight, missing }

    /// When you'd be on the platform (or at the stop).
    var ready: Date
    /// How long before it leaves; negative if you'd miss it.
    var spare: TimeInterval

    var verdict: Verdict {
        if spare >= 120 { .comfortable } else if spare >= 0 { .tight } else { .missing }
    }

    /// Ordinary walking pace; a measured one replaces it while moving.
    static let walkingSpeed = 1.35

    /// Time from the station door to the platform, which walking routes stop short of.
    static func platformTime(_ mode: LegMode) -> TimeInterval {
        switch mode {
        case .bus, .coach, .tram: 30
        case .tube, .elizabeth, .dlr, .overground, .rail: 90
        default: 60
        }
    }

    static func make(remaining: Double, speed: Double?, now: Date, departure: Date, mode: LegMode) -> Connection {
        let pace = speed.map { min(max($0, 0.8), 2.5) } ?? walkingSpeed
        let ready = now.addingTimeInterval(remaining / pace + platformTime(mode))
        return Connection(ready: ready, spare: departure.timeIntervalSince(ready))
    }
}

/// Which leg of a journey you're on, worked out from the clock and where you are.
enum TripProgress {
    /// Within this of a walk's end, you've arrived.
    static let arrivedDistance: Double = 35

    /// Where to start when a trip begins: the first leg not yet over.
    static func initialLeg(_ journey: Journey, now: Date) -> Int {
        journey.legs.firstIndex { $0.arrival > now } ?? max(0, journey.legs.count - 1)
    }

    /// Within this of where a ride gets off, you're there, whatever the clock says.
    static let alightedDistance: Double = 60

    /// Moves on past legs that are done. A walk is done when you reach its end; a
    /// ride when you're at its stop off, or when it's due in unless you're still
    /// standing where it left from (underground there's no fix, so time decides).
    /// `rideArrival` is when the ride you're on really gets in, where that's known
    /// (an earlier or later bus than planned); `arrivals` are every leg's re-timed
    /// arrivals (`TripTimeline`), where Go has them.
    static func advance(_ journey: Journey, from start: Int, now: Date, location: Coordinate?, rideArrival: Date? = nil,
                        arrivals: [Date]? = nil) -> Int {
        var index = start
        while index < journey.legs.count - 1 {
            let leg = journey.legs[index]
            if leg.mode.isTransit {
                let atStart = location.flatMap { here in leg.start.map { here.distance(to: $0) < 150 } } ?? false
                if !atStart, let location, let end = leg.end, location.distance(to: end) < alightedDistance {
                    index += 1
                    continue
                }
                let due = (index == start ? rideArrival : nil) ?? arrivals?[safe: index] ?? leg.arrival
                guard now >= due.addingTimeInterval(-30), !atStart else { break }
            } else {
                guard let location, let end = leg.end, location.distance(to: end) < arrivedDistance else { break }
            }
            index += 1
        }
        return index
    }

    /// Still at the stop after the ride should have left (`departure`, where it's
    /// known live): you missed it.
    static func missed(_ leg: Leg, now: Date, location: Coordinate?, departure: Date? = nil) -> Bool {
        guard leg.mode.isTransit, now > (departure ?? leg.departure).addingTimeInterval(60),
              let location, let start = leg.start else { return false }
        return location.distance(to: start) < 150
    }
}

/// Notices you're already on a ride, say an earlier bus than planned, or Go started
/// once aboard: on its line, past where you'd get on, and moving along it faster
/// than anyone walks. Underground there's no fix, so it can't tell; the buttons can.
struct BoardingDetector {
    private var samples: [(at: Date, leg: Int, along: Double)] = []

    /// Within this of a ride's line counts as on it.
    static let onLineDistance: Double = 50
    /// Past where it starts by this much, so standing at the stop isn't riding.
    static let pastStart: Double = 100
    /// Average speed along the line that walking (or running for it) doesn't reach.
    static let ridingSpeed: Double = 3.5
    static let minimumProgress: Double = 50

    /// The ride you're on, among the legs from `first`, once you've shown it.
    mutating func ride(_ journey: Journey, from first: Int, location: Coordinate?, now: Date) -> Int? {
        samples.removeAll { now.timeIntervalSince($0.at) > 120 }
        guard let location, first < journey.legs.count else { return nil }
        for index in first..<journey.legs.count {
            let leg = journey.legs[index]
            guard leg.mode.isTransit, leg.path.count > 1,
                  let progress = PathProgress.locate(location, on: leg.path),
                  progress.distanceFromPath <= Self.onLineDistance,
                  progress.distanceAlong >= Self.pastStart, progress.remaining > 30 else { continue }
            defer { samples.append((now, index, progress.distanceAlong)) }
            // Going its way, at a ride's pace, over the last little while.
            let riding = samples.contains { sample in
                let seconds = now.timeIntervalSince(sample.at)
                let gained = progress.distanceAlong - sample.along
                return sample.leg == index && seconds >= 6 && gained >= Self.minimumProgress && gained / seconds >= Self.ridingSpeed
            }
            if riding { return index }
        }
        return nil
    }

    mutating func reset() { samples.removeAll() }
}

/// What missing a ride does to the whole journey: the next one instead, then each
/// later change, made or missed in turn. Times come from the plan, moved by what
/// the departure boards know (live delays, the next one's arrival); a later change
/// you'd miss takes the soonest one on its board that you can still make.
struct IfMissed: Equatable, Sendable {
    /// What you'd catch instead.
    var next: Departure
    /// Minutes later at the destination than if you make it; nil when a missed
    /// change has no board to say what comes after it.
    var cost: Int?
    /// Nothing on a missed change's board leaves late enough: at least this late.
    var costIsFloor = false
    /// The first later change you'd lose, or else the next one you'd still make.
    var connection: Leg?
    var losesConnection = false

    /// Extra time to change when the next ride is late, on top of any walk between.
    static let changeMargin: TimeInterval = 60

    static func make(_ journey: Journey, ride index: Int, board: (Leg) -> DepartureBoard?) -> IfMissed? {
        let ride = journey.legs[index]
        guard let rideBoard = board(ride), let planned = rideBoard.planned, let next = rideBoard.nextAfterPlanned else { return nil }
        let lateBy = rideBoard.arrivalDifference(next) ?? next.expected.timeIntervalSince(planned.expected)
        // How far the one you're going for sits from the leg's own time: its delay on the
        // plan, nothing on a re-timed journey whose leg is already that departure.
        let offset = planned.expected.timeIntervalSince(ride.departure)
        let made = follow(journey, after: index, from: ride.arrival.addingTimeInterval(offset), board: board, margin: 0)
        let missed = follow(journey, after: index, from: ride.arrival.addingTimeInterval(offset + lateBy),
                            board: board, margin: changeMargin)

        var result = IfMissed(next: next)
        if let lost = zip(made.changes, missed.changes).first(where: { $0.made && !$1.made }) {
            result.connection = lost.0.leg
            result.losesConnection = true
        } else if let kept = missed.changes.first, kept.made {
            result.connection = kept.leg
        }
        if let late = missed.arrival, let onTime = made.arrival {
            result.cost = Int((late.timeIntervalSince(onTime) / 60).rounded())
            result.costIsFloor = missed.isFloor
        }
        return result
    }

    private struct Path {
        var changes: [(leg: Leg, made: Bool)] = []
        var arrival: Date?
        var isFloor = false
    }

    /// Travels the legs after `index`, reaching the end of that ride at `start`.
    private static func follow(_ journey: Journey, after index: Int, from start: Date,
                               board: (Leg) -> DepartureBoard?, margin: TimeInterval) -> Path {
        var path = Path()
        var at = start
        for leg in journey.legs.dropFirst(index + 1) {
            guard leg.mode.isTransit else {
                at = at.addingTimeInterval(leg.duration)
                continue
            }
            let known = board(leg)
            let delay = known?.planned.map { $0.expected.timeIntervalSince(leg.departure) } ?? 0
            if leg.departure.addingTimeInterval(delay) >= at.addingTimeInterval(margin) {
                path.changes.append((leg, true))
                at = leg.arrival.addingTimeInterval(delay)
                continue
            }
            path.changes.append((leg, false))
            guard let known else { return path }
            let running = known.departures.filter { !$0.isCancelled }
            let ready = at.addingTimeInterval(margin)
            let there = { (d: Departure) in d.arrivalThere ?? d.expected.addingTimeInterval(leg.duration) }
            if let catchable = running.filter({ $0.expected >= ready }).min(by: { there($0) < there($1) }) {
                at = there(catchable)
            } else {
                // Nothing on the board leaves late enough, so the one that does leaves after the board ends.
                let boardEnds = leg.departure.addingTimeInterval(DepartureProvider.boardSpan - DepartureProvider.boardLead)
                at = max(ready, boardEnds).addingTimeInterval(leg.duration)
                path.isFloor = true
            }
        }
        path.arrival = at
        return path
    }
}

/// What has really happened on a trip so far: which departure you got on, and when
/// you finished each leg. Go writes it as you go; `TripTimeline` re-times the rest from it.
struct TripLog: Codable, Equatable, Sendable {
    struct Boarding: Codable, Equatable, Sendable {
        var at: Date
        /// Off the ride's board, the one you got on, where there's a board to say.
        var departure: Departure?
    }

    /// When Go started.
    var began: Date
    /// By leg index. Stamped once, when you say so or Go sees you riding.
    var boardings: [Int: Boarding] = [:]
    /// When each leg was finished: off a ride, or at a walk's end.
    var ended: [Int: Date] = [:]

    /// Jumped back to a leg by hand: forget what happened from there on.
    mutating func rewind(to index: Int) {
        boardings = boardings.filter { $0.key < index }
        ended = ended.filter { $0.key < index }
    }

    /// Further than this from any departure on the board, the moment itself stands in.
    static let snapWindow: TimeInterval = 5 * 60

    /// The departure you got on at `at`: the one nearest that moment. Go hears it once
    /// you're aboard (you tap, or it sees you moving), so one that has just left
    /// counts as nearer than one still to come.
    static func departure(boardedAt at: Date, on board: DepartureBoard?) -> Departure? {
        guard let board else { return nil }
        let distance = { (departure: Departure) -> TimeInterval in
            let gap = departure.expected.timeIntervalSince(at)
            return gap > 0 ? gap * 1.5 : -gap
        }
        guard let nearest = board.departures.filter({ !$0.isCancelled }).min(by: { distance($0) < distance($1) }),
              distance(nearest) <= snapWindow else { return nil }
        return nearest
    }
}

/// The journey as it's really going: every leg re-timed from what you've done
/// (`TripLog`) and what the departure boards already held say, through to the
/// arrival. A ride you're on runs from the departure you got on; one ahead is the
/// planned departure while you're on plan, the soonest one there you can still make
/// once you're early or late, and a guess past what the boards know.
struct TripTimeline: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        var departure: Date
        var arrival: Date
        /// For a ride: the departure off its board you're on, or the one you'll now catch.
        var service: Departure?
        /// Past what the boards know (or with none): a guess at the soonest it could be.
        var isEstimate = false
    }

    /// The plan with each leg's times replaced by the re-timed ones (same legs, same ids).
    var journey: Journey
    /// One per leg.
    var steps: [Step]

    /// When you'll get there now.
    var arrival: Date { journey.arrival }

    /// Time to change trains, where the plan leaves at least that much.
    static let changeMargin: TimeInterval = 60
    /// Within this of the plan, you're on it: keep the planned departure.
    static let onPlan: TimeInterval = 60

    /// The timeline before anything has happened.
    static func plan(_ journey: Journey) -> TripTimeline {
        TripTimeline(journey: journey, steps: journey.legs.map { Step(departure: $0.departure, arrival: $0.arrival) })
    }

    /// - Parameters:
    ///   - current: the leg you're on.
    ///   - seenAtStop: on the ride you're at and not aboard, the last fix that put you at
    ///     its stop. After the planned one has left, you missed it: the next one counts.
    ///   - liveArrival: when the vehicle you're on gets in, where the operator says (TfL's buses).
    ///   - walkLeft: on the walk you're on, seconds of walking left, from a fix.
    static func make(_ plan: Journey, log: TripLog, current: Int, now: Date, seenAtStop: Date? = nil,
                     liveArrival: Date? = nil, walkLeft: TimeInterval? = nil,
                     board: (Leg) -> DepartureBoard?) -> TripTimeline {
        var steps: [Step] = []
        // When you're free to start the next leg.
        var ready: Date?
        for (index, leg) in plan.legs.enumerated() {
            let step: Step
            if leg.mode.isTransit {
                step = ride(plan, index, log: log, current: current, now: now, ready: ready, seenAtStop: seenAtStop,
                            liveArrival: index == current ? liveArrival : nil, board: board)
                // Still aboard after it was due: the rest waits on it.
                ready = index == current && log.boardings[index] != nil && log.ended[index] == nil
                    ? max(step.arrival, now) : step.arrival
            } else {
                let start = ready ?? (index == current ? max(leg.departure, log.began) : leg.departure)
                var end = log.ended[index] ?? start.addingTimeInterval(leg.duration)
                // A fix showing more walking left than the plan allows moves it on. With no fix
                // (deep underground at a change) it keeps its planned time: stretching it with
                // the clock would push the next train back for as long as there's no signal.
                if log.ended[index] == nil, index == current, let walkLeft {
                    end = max(end, now.addingTimeInterval(walkLeft))
                }
                step = Step(departure: min(start, end), arrival: end)
                ready = end
            }
            steps.append(step)
        }
        // A leg already done can't have ended after the ride that followed it left (you
        // got on the one that had just gone): it ended by then.
        for index in steps.indices.dropFirst() where index - 1 < current && steps[index - 1].arrival > steps[index].departure {
            steps[index - 1].arrival = steps[index].departure
            steps[index - 1].departure = min(steps[index - 1].departure, steps[index].departure)
        }
        var journey = plan
        for (index, step) in steps.enumerated() {
            journey.legs[index].departure = step.departure
            journey.legs[index].arrival = step.arrival
        }
        if let first = steps.first, let last = steps.last {
            journey.departure = first.departure
            journey.arrival = last.arrival
        }
        return TripTimeline(journey: journey, steps: steps)
    }

    private static func ride(_ plan: Journey, _ index: Int, log: TripLog, current: Int, now: Date, ready: Date?,
                             seenAtStop: Date?, liveArrival: Date?, board: (Leg) -> DepartureBoard?) -> Step {
        let leg = plan.legs[index]
        let ended = log.ended[index]
        // On it: from the departure you got on, or the moment you did.
        if let boarding = log.boardings[index] {
            let departure = boarding.departure?.expected ?? boarding.at
            let arrival = ended ?? liveArrival ?? boarding.departure?.arrivalThere ?? departure.addingTimeInterval(leg.duration)
            return Step(departure: departure, arrival: arrival, service: boarding.departure)
        }

        let known = board(leg)
        let running = known?.departures.filter { !$0.isCancelled } ?? []
        let planned = known?.planned.flatMap { $0.isCancelled ? nil : $0 }
        let timed = { (departure: Departure) in
            Step(departure: departure.expected,
                 arrival: departure.arrivalThere ?? departure.expected.addingTimeInterval(leg.duration), service: departure)
        }
        let asPlanned = planned.map(timed) ?? Step(departure: leg.departure, arrival: leg.arrival)
        // Whatever leaves from `from` and gets there first.
        let soonest = { (from: Date) -> Step? in
            running.filter { $0.expected >= from }
                .min { ($0.arrivalThere ?? $0.expected, $0.expected) < ($1.arrivalThere ?? $1.expected, $1.expected) }
                .map(timed)
        }
        // Nothing known leaves late enough: at least as late as the board reaches.
        let beyond = { (from: Date) -> Step in
            let boardEnds = known == nil ? from : leg.departure.addingTimeInterval(DepartureProvider.boardSpan - DepartureProvider.boardLead)
            let departure = max(from, boardEnds)
            return Step(departure: departure, arrival: departure.addingTimeInterval(leg.duration), isEstimate: true)
        }
        let plannedCancelled = known?.plannedID != nil && planned == nil

        var step: Step
        if index < current {
            // Passed without a word: as planned.
            step = asPlanned
        } else if index == current || (index == current + 1 && current == 0 && !plan.legs[current].mode.isTransit) {
            // The ride you're at, or walking to from the start (you choose when to set off):
            // the planned one until it's gone. Seen still at the stop after it left, the next
            // one you could have caught since; walking to it after it left, the next you'll
            // reach. You get on earlier ones by saying so. A change you walk to after a ride
            // is timed from that ride, below.
            let reach = max(now, ready ?? now)
            if index == current, let seen = seenAtStop, seen > asPlanned.departure.addingTimeInterval(60) {
                step = soonest(seen.addingTimeInterval(-30)) ?? beyond(seen)
            } else if index > current, now > asPlanned.departure.addingTimeInterval(60) {
                step = soonest(reach) ?? beyond(reach)
            } else if plannedCancelled {
                step = soonest(reach) ?? beyond(reach)
            } else {
                step = asPlanned
            }
        } else {
            // A later ride: when you'd reach it against when the plan did.
            let at = ready ?? leg.departure
            let plannedAt = index > 0 ? plan.legs[index - 1].arrival : leg.departure
            let margin = min(changeMargin, max(0, leg.departure.timeIntervalSince(plannedAt)))
            let from = at.addingTimeInterval(margin)
            let shift = at.timeIntervalSince(plannedAt)
            if abs(shift) < onPlan, !plannedCancelled {
                step = asPlanned
            } else if shift < 0 {
                // Early: whatever you can now make that gets there first.
                step = soonest(from) ?? asPlanned
            } else if asPlanned.departure >= from, !plannedCancelled {
                step = asPlanned
            } else {
                step = soonest(from) ?? beyond(from)
            }
        }
        if let ended {
            step.arrival = ended
            step.departure = min(step.departure, ended)
        }
        return step
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
