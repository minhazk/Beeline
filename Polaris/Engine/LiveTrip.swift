import CoreLocation
import Foundation
import Observation

/// A journey being travelled: which leg you're on, turn-by-turn on the walks,
/// whether you'll make the next departure, and the whole trip re-timed from what
/// you actually do (`timeline`).
@MainActor @Observable
final class LiveTrip {
    /// The plan, as found, or as switched to mid-trip (`acceptOffer`). What really happens is
    /// in `log` and `timeline`.
    private(set) var journey: Journey
    let query: JourneyQuery
    private(set) var legIndex: Int
    /// The walk you're on, routed from where you are.
    private(set) var walk: WalkRoute?
    private(set) var walkProgress: PathProgress?
    private(set) var now: Date
    /// What you've done: which departures you got on, and when you finished each leg.
    private(set) var log: TripLog
    /// The journey re-timed from `log` and the boards already held: which departure
    /// you're on or will catch, when you get off, and when you arrive. Every time on
    /// screen, on the Lock Screen and in the alerts comes from here.
    private(set) var timeline: TripTimeline

    /// Re-planning, as a satnav does: looking for a faster way, offering one, or saying why not.
    enum ReplanState: Equatable {
        case idle
        /// "Find a faster way", running.
        case looking(Replan.Origin)
        case offer(Replan.Offer, reason: Replan.Reason)
        /// Asked by hand: nothing beat the trip, or no signal to ask with.
        case said(Replan.Message)
    }

    private(set) var replan: ReplanState = .idle
    /// What this trip has asked (caps, spacing, reasons settled).
    private(set) var replanWatch = Replan.Watch()
    /// The search running, if any; tests wait on it.
    private(set) var replanTask: Task<Void, Never>?
    /// Long waits a search found nothing better for: their line says so.
    private var checkedWaits: Set<String> = []
    /// Go looks for a reason only when this changes: the rides ahead, the leg, a boarding or a leg ended.
    private var lastReplanEvent: [String]?
    /// The trip Go is following, for a notification's Switch and Keep buttons.
    static weak var current: LiveTrip?

    /// A location fix and when it was taken.
    struct Fix: Equatable, Sendable {
        var coordinate: Coordinate
        var at: Date
        var horizontalAccuracy: Double = 5
    }

    enum Completion: Equatable { case arrived, expired }
    var onCompletion: ((Completion) -> Void)?
    private(set) var completion: Completion?
    private var stopped = false
    private var wasAwayFromDestination = false
    private var firstArrivalFix: Date?
    /// An ETA based on the remaining walk can keep moving even when the phone is stationary.
    static let expiryGrace: TimeInterval = 3 * 60 * 60

    private let location: LocationService
    private let departures: DepartureStore
    private let buses: LiveBusStore
    private let clock: @MainActor () -> Date
    private let fixSource: @MainActor () -> Fix?
    private let timetable: @MainActor (Leg) -> DepartureBoard?
    private let loadBoard: @MainActor (Leg) async -> Void
    private let routeWalk: @MainActor (Coordinate, Coordinate) async -> WalkRoute?
    private let alerts: any TripAlertScheduling
    private let search: ReplanSearch.Search?
    private let isOnline: @MainActor () -> Bool
    /// The alerts last handed over, so they're only rescheduled when they move.
    private var sentAlerts: [TripAlert]?
    private var detector = BoardingDetector()
    /// The bus you're on, once picked out, so a passing one doesn't take its place.
    private var yourBusID: String?
    /// The bus you're going for, by ride, so two about as near the timetable's time
    /// don't take turns being it as TfL's times shift.
    private var chosenBus: (ride: UUID, vehicle: String)?
    private let activity: any TripActivityDriving
    /// Where the trip is kept for a relaunch; nil keeps it in memory only (tests).
    private let store: TripStore?
    /// What was last written there, so only a change writes again.
    private var lastSaved: SavedTrip?
    /// How many times the trip has been written; tests check it isn't every tick.
    private(set) var saveCount = 0
    /// Picked up after Polaris was closed (`init(resuming:)`), not started afresh.
    let isResumed: Bool
    /// Catching up on time passed while closed: nothing is published or asked until it's done.
    private var catchingUp = false
    /// Resumed with no fix yet: since when Go has waited for the first one, to catch up by it.
    private var awaitingFix: Date?
    private var lookedForFix = false
    /// Resumed: no re-plan is asked while the boards are still coming in (what they change is
    /// the restore's doing, not an event), for up to a minute.
    private var quietSince: Date?
    /// Resumed: the alerts handed over before Polaris closed are still pending with the system,
    /// so the first plan keeps any due within its lead rather than dropping it.
    private var alertsMayBePending = false
    /// Resumed: the rides whose boards the restore waits on before re-planning.
    private var quietLegs: Set<UUID> = []
    /// Resumed with a faster way that was on show: its reason, for a Keep or Switch tapped on
    /// its notification after the relaunch.
    private var savedOfferKey: String?
    private var tick: Task<Void, Never>?
    private var routing: Task<Void, Never>?
    private var lastRoute: (at: Date, legIndex: Int)?

    /// Off the route by more than this and it re-routes.
    static let offRouteDistance: Double = 40

    /// The clock, fixes, boards and alerts default to the real ones; tests pass their own.
    init(journey: Journey, query: JourneyQuery, location: LocationService, departures: DepartureStore,
         buses: LiveBusStore = LiveBusStore(),
         clock: @escaping @MainActor () -> Date = { .now },
         fix: (@MainActor () -> Fix?)? = nil,
         boards: (@MainActor (Leg) -> DepartureBoard?)? = nil,
         loadBoard: (@MainActor (Leg) async -> Void)? = nil,
         routeWalk: (@MainActor (Coordinate, Coordinate) async -> WalkRoute?)? = nil,
         alerts: (any TripAlertScheduling)? = nil,
         search: ReplanSearch.Search? = nil,
         isOnline: (@MainActor () -> Bool)? = nil,
         activity: (any TripActivityDriving)? = nil,
         store: TripStore? = nil,
         saved: SavedTrip? = nil) {
        self.journey = saved?.journey ?? journey
        self.query = saved?.query ?? query
        self.location = location
        self.departures = departures
        self.buses = buses
        self.clock = clock
        self.fixSource = fix ?? { [location] in
            location.live.map { Fix(coordinate: Coordinate($0.coordinate), at: $0.timestamp, horizontalAccuracy: $0.horizontalAccuracy) }
        }
        self.timetable = boards ?? { [departures] in departures.board($0)?.value }
        self.loadBoard = loadBoard ?? { [departures] in await departures.load($0) }
        self.routeWalk = routeWalk ?? { try? await WalkRouter.route(from: $0, to: $1) }
        self.alerts = alerts ?? SystemTripAlerts()
        self.search = search
        self.isOnline = isOnline ?? { NetworkPath.shared.isOnline }
        self.activity = activity ?? TripActivity()
        self.store = store
        let now = clock()
        self.now = now
        if let saved {
            // As it was when last saved; `start` (or `catchUp`) brings it up to now.
            isResumed = true
            log = saved.log
            legIndex = min(max(0, saved.legIndex), saved.journey.legs.count - 1)
            replanWatch = saved.replanWatch
            checkedWaits = saved.checkedWaits
            lastSaved = saved
            quietSince = now
            alertsMayBePending = true
            quietLegs = Set(saved.journey.legs.dropFirst(saved.legIndex).filter(\.mode.isTransit).map(\.id))
            savedOfferKey = saved.offerKey
        } else {
            isResumed = false
            log = TripLog(began: now)
            legIndex = TripProgress.initialLeg(journey, now: now)
        }
        timeline = .plan(saved?.journey ?? journey)
        retime()
    }

    /// A trip picked up after Polaris was closed, from what was saved (`TripStore`).
    convenience init(resuming saved: SavedTrip, location: LocationService, departures: DepartureStore,
                     buses: LiveBusStore = LiveBusStore(),
                     clock: @escaping @MainActor () -> Date = { .now },
                     fix: (@MainActor () -> Fix?)? = nil,
                     boards: (@MainActor (Leg) -> DepartureBoard?)? = nil,
                     loadBoard: (@MainActor (Leg) async -> Void)? = nil,
                     routeWalk: (@MainActor (Coordinate, Coordinate) async -> WalkRoute?)? = nil,
                     alerts: (any TripAlertScheduling)? = nil,
                     search: ReplanSearch.Search? = nil,
                     isOnline: (@MainActor () -> Bool)? = nil,
                     activity: (any TripActivityDriving)? = nil,
                     store: TripStore? = nil) {
        self.init(journey: saved.journey, query: saved.query, location: location, departures: departures, buses: buses,
                  clock: clock, fix: fix, boards: boards, loadBoard: loadBoard, routeWalk: routeWalk, alerts: alerts,
                  search: search, isOnline: isOnline, activity: activity, store: store, saved: saved)
    }

    var leg: Leg { journey.legs[legIndex] }
    var isLastLeg: Bool { legIndex == journey.legs.count - 1 }
    /// Your latest fix, however old: the map's dot.
    var position: Coordinate? { fixSource()?.coordinate }
    /// You're on the ride you're at: seen moving along it, or you said so.
    var boarded: Bool { log.boardings[legIndex] != nil }

    /// When you'll get there, as the trip is going.
    var eta: Date { timeline.arrival }

    /// Where you are as far as the leg you're on goes. A fix from before you got on
    /// the ride (or before it left) or before you got off it says where you were, not
    /// where you are: underground the phone keeps the last one from the platform.
    var trustedPosition: Coordinate? {
        guard let fix = fixSource() else { return nil }
        if leg.mode.isTransit {
            // On a ride, only a fix taken since you got on (or since it left) counts.
            guard let since = log.boardings[legIndex]?.at ?? (isWaiting ? nil : rideDeparture) else { return fix.coordinate }
            return fix.at >= since ? fix.coordinate : nil
        }
        if legIndex > 0, let since = log.ended[legIndex - 1], fix.at < since.addingTimeInterval(-30) { return nil }
        return fix.coordinate
    }

    /// On a ride with no fix to go on (underground): where it has got to by the
    /// clock, for the map to draw as an estimate rather than a fix.
    var estimatedPosition: Coordinate? {
        guard leg.mode.isTransit, !isWaiting, leg.path.count > 1, trustedPosition == nil,
              let step = timeline.steps[safe: legIndex] else { return nil }
        let span = step.arrival.timeIntervalSince(step.departure)
        guard span > 0 else { return nil }
        let fraction = min(1, max(0, now.timeIntervalSince(step.departure) / span))
        return PathProgress.point(along: fraction * PathProgress.length(of: leg.path), on: leg.path)
    }

    /// The ride this walk leads to, if any.
    var nextRide: Leg? {
        guard !leg.mode.isTransit, legIndex + 1 < journey.legs.count else { return nil }
        let next = journey.legs[legIndex + 1]
        return next.mode.isTransit ? next : nil
    }

    var board: DepartureBoard? { nextRide.flatMap(board(for:)) }

    /// A ride's departures, with the one the timeline has you on (or catching) as its
    /// planned one, so what's said about missing it is about that one.
    func board(for ride: Leg) -> DepartureBoard? {
        guard var board = rawBoard(for: ride) else { return nil }
        if let index = journey.legs.firstIndex(where: { $0.id == ride.id }), index >= legIndex,
           let step = timeline.steps[safe: index] {
            board.plannedID = step.service?.id
        }
        return board
    }

    /// TfL's live buses for the bus you're going for, otherwise the timetable's.
    private func rawBoard(for ride: Leg) -> DepartureBoard? {
        let timetable = timetable(ride)
        let preferred = chosenBus?.ride == ride.id ? chosenBus?.vehicle : nil
        return buses.board(for: ride, timetable: timetable, preferred: preferred) ?? timetable
    }

    /// When the ride you're walking to leaves: the departure the timeline has you catching.
    var nextRideDeparture: Date? {
        guard nextRide != nil else { return nil }
        return timeline.steps[safe: legIndex + 1]?.departure
    }

    /// When the ride you're at leaves: the one you got on, or the one you'll catch.
    var rideDeparture: Date { timeline.steps[safe: legIndex]?.departure ?? leg.departure }

    /// When the planned departure of the ride you're at leaves, live if the board has it.
    private var plannedRideDeparture: Date { rawBoard(for: leg)?.planned?.expected ?? leg.departure }

    /// At the stop, waiting for the ride: not on it yet, and it hasn't gone.
    var isWaiting: Bool { leg.mode.isTransit && !boarded && now < rideDeparture }

    /// The ride you're heading for: the one you're walking to, or this one until it leaves.
    private var upcomingRide: Int? {
        if nextRide != nil { return legIndex + 1 }
        return isWaiting ? legIndex : nil
    }

    /// The bus line to show live on the map: the bus you're on or waiting for, or walking to.
    var busWatch: BusWatch? {
        if leg.mode == .bus { return BusWatch(leg: leg) }
        return nextRide.flatMap(BusWatch.init(leg:))
    }

    /// The bus you're on, from TfL's live positions: the one alongside you.
    var yourBus: TfLBuses.Bus? {
        guard boarded, let watch = busWatch, leg.mode == .bus, buses.watch == watch else { return nil }
        let all = buses.buses
        if let yourBusID, let bus = all.first(where: { $0.id == yourBusID }) { return bus }
        guard let position else { return nil }
        return all.map { ($0, $0.coordinate.distance(to: position)) }.filter { $0.1 < 150 }.min { $0.1 < $1.1 }?.0
    }

    /// When the ride you're on gets you there: from the departure you got on (your
    /// bus's own time where TfL has it).
    var rideArrival: Date { timeline.steps[safe: legIndex]?.arrival ?? leg.arrival }

    /// The departure you're on, once Go knows which.
    var yourDeparture: Departure? { log.boardings[legIndex]?.departure }

    /// What missing that ride does to your arrival, through every later change.
    var ifMissed: IfMissed? {
        upcomingRide.flatMap { IfMissed.make(timeline.journey, ride: $0) { board(for: $0) } }
    }

    var guidance: (instruction: String?, distance: Double)? {
        guard let walk, !leg.mode.isTransit else { return nil }
        return walk.guidance(at: walkProgress?.distanceAlong ?? 0)
    }

    var remainingWalk: Double? {
        guard !leg.mode.isTransit else { return nil }
        return walkProgress?.remaining ?? walk?.distance ?? leg.distanceMeters
    }

    /// Your walking pace while moving, else an ordinary one.
    private var pace: Double {
        location.live.flatMap { $0.speed > 0.6 && $0.speed < 3 ? $0.speed : nil } ?? Connection.walkingSpeed
    }

    var connection: Connection? {
        guard let ride = nextRide, let departure = nextRideDeparture, let remaining = remainingWalk,
              trustedPosition != nil else { return nil }
        let speed = location.live.flatMap { $0.speed > 0.6 && $0.speed < 3 ? $0.speed : nil }
        return Connection.make(remaining: remaining, speed: speed, now: now, departure: departure, mode: ride.mode)
    }

    /// Still at the stop after the planned one left (a fix taken since says so).
    var missedRide: Bool {
        guard !boarded, let fix = fixSource(), fix.at > plannedRideDeparture else { return false }
        return TripProgress.missed(leg, now: now, location: fix.coordinate, departure: plannedRideDeparture)
    }

    /// What the one-tap step button does now, if anything: tell Go you're on the ride
    /// (an earlier one, say, or underground where it can't see), or that you're off.
    enum Step: Equatable {
        case boarded(Leg)
        case gotOff(Leg)
    }

    var manualStep: Step? {
        if let ride = nextRide { return .boarded(ride) }
        guard leg.mode.isTransit, !isLastLeg else { return nil }
        return isWaiting ? .boarded(leg) : .gotOff(leg)
    }

    func take(_ step: Step) {
        guard !stopped else { return }
        now = clock()
        switch step {
        case .boarded(let ride):
            guard let index = journey.legs.firstIndex(where: { $0.id == ride.id }) else { return }
            if index != legIndex { moveTo(index) }
            recordBoarding(index)
        case .gotOff:
            guard legIndex + 1 < journey.legs.count else { return }
            moveTo(legIndex + 1)
        }
        retime()
        publish()
    }

    func start() {
        guard !stopped, tick == nil else { return }
        Self.current = self
        location.startTracking()
        now = clock()
        if isResumed { catchUp() }
        retime()
        // Picked up again: the Live Activity on the Lock Screen is this trip's, so carry on with it.
        activity.start(destination: query.destination.name, state: activityState(), adopt: isResumed)
        // A faster way on show when Polaris closed wasn't kept: its notification's Switch would do nothing.
        if isResumed { alerts.offer(nil) }
        publish()
        // Later changes' boards say what missing a ride costs and re-time the trip.
        // The journey page has usually loaded them; fetch any it hasn't, once (only
        // the next ride's refreshes).
        let later = journey.legs.dropFirst(legIndex).filter { $0.mode.isTransit && timetable($0) == nil }
        Task { [loadBoard] in for ride in later { await loadBoard(ride) } }
        tick = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        tick?.cancel()
        tick = nil
        routing?.cancel()
        location.stopTracking()
        activity.end()
        alerts.cancel()
        alerts.offer(nil)
        sentAlerts = nil
        replanTask?.cancel()
        replanTask = nil
        // Ended: nothing to pick up next launch.
        store?.clear()
        lastSaved = nil
        if Self.current === self { Self.current = nil }
    }

    private func complete(_ reason: Completion) {
        completion = reason
        stop()
        onCompletion?(reason)
    }

    /// Two distinct, recent fixes must place the phone at the destination on the final leg.
    /// A loop starting at its finish must first leave it. On resume, a confirmed boarding
    /// at a distant stop also proves the traveller has been away.
    private func reachedDestination() -> Bool {
        guard let fix = fixSource(), (0...25).contains(fix.horizontalAccuracy),
              (0...30).contains(now.timeIntervalSince(fix.at)), fix.at >= log.began else {
            firstArrivalFix = nil
            return false
        }
        let destination = query.destination.coordinate
        let distance = fix.coordinate.distance(to: destination)
        if distance - fix.horizontalAccuracy > 75 { wasAwayFromDestination = true }
        let radius = leg.mode.isTransit ? TripProgress.alightedDistance : TripProgress.arrivedDistance
        guard isLastLeg, distance + fix.horizontalAccuracy <= radius else {
            firstArrivalFix = nil
            return false
        }
        guard wasAwayFromDestination || log.boardings.keys.contains(where: {
            guard let start = journey.legs[safe: $0]?.start else { return false }
            return start.distance(to: destination) > 100
        }) else { return false }
        if let first = firstArrivalFix {
            let elapsed = fix.at.timeIntervalSince(first)
            if (3...30).contains(elapsed) { return true }
            if (0..<3).contains(elapsed) { return false }
        }
        firstArrivalFix = fix.at
        return false
    }

    /// Picked up after Polaris was closed: one look at the clock and where you are, as a tick
    /// takes, for the time it was closed. A ride the clock finished ends when it got in, not
    /// now, so later times don't slip; and nothing that happened while closed sets off a
    /// re-plan (a restore never searches). `start` does this; tests call it alone.
    func catchUp() {
        catchingUp = true
        // By the clock first: a ride due in has ended, when it was due.
        refresh()
        let hadFix = jumpToFix()
        catchingUp = false
        lastReplanEvent = replanEvent
        // Tracking has only just started, so there's usually no fix yet: the first one gets
        // the same look, if it comes within two minutes.
        if !hadFix, awaitingFix == nil, !lookedForFix { awaitingFix = now }
        lookedForFix = true
    }

    /// A fresh fix at the end of a leg further on says you got that far while Polaris was
    /// closed (off the train and on to the next platform, or there): walks end only where
    /// you're seen, and no tick saw you. The legs passed end when the timeline has them end,
    /// not stretched to where you are now (as a far-off fix would stretch a walk).
    /// Whether there was a fresh fix to go on.
    private func jumpToFix() -> Bool {
        guard let fix = fixSource(), now.timeIntervalSince(fix.at) < 120 else { return false }
        if let reached = journey.legs.indices.dropFirst(legIndex).last(where: { index in
               let leg = journey.legs[index]
               let near = leg.mode.isTransit ? TripProgress.alightedDistance : TripProgress.arrivedDistance
               return leg.end.map { fix.coordinate.distance(to: $0) < near } ?? false
           }), min(reached + 1, journey.legs.count - 1) > legIndex {
            walkProgress = nil
            retime()
            // At the end itself: on the last leg, there.
            moveTo(min(reached + 1, journey.legs.count - 1))
            refresh()
        }
        return true
    }

    /// Jump to a leg by hand; automatic progress carries on from there.
    func select(_ index: Int) {
        guard journey.legs.indices.contains(index), index != legIndex else { return }
        now = clock()
        moveTo(index)
    }

    /// One look at the clock and where you are. Go does this every two seconds.
    func refresh() {
        guard !stopped else { return }
        now = clock()
        if !catchingUp, now > max(log.began, journey.arrival).addingTimeInterval(Self.expiryGrace) {
            complete(.expired)
            return
        }
        // Resumed before any fix: the first fresh one catches the trip up as the launch would have.
        if let since = awaitingFix, !catchingUp {
            if now.timeIntervalSince(since) > 120 {
                awaitingFix = nil
            } else if let fix = fixSource(), now.timeIntervalSince(fix.at) < 120 {
                awaitingFix = nil
                catchUp()
                publish()
                return
            }
        }
        // Already aboard (an earlier bus, or Go started on it): catch up to that ride.
        if let ride = detector.ride(journey, from: boarded ? legIndex + 1 : legIndex, location: position, now: now) {
            if ride != legIndex { moveTo(ride) }
            recordBoarding(ride, at: boardedBefore(ride))
        }
        if boarded, let bus = yourBus { yourBusID = bus.id }
        // Hold on to the bus you're going for while it's still coming.
        if let ride = nextRide ?? (isWaiting ? leg : nil), ride.mode == .bus,
           let id = rawBoard(for: ride)?.plannedID, id.hasPrefix("tfl-") {
            chosenBus = (ride.id, String(id.dropFirst(4)))
        }
        retime()
        var advanced = TripProgress.advance(journey, from: legIndex, now: now, location: trustedPosition,
                                            rideArrival: leg.mode.isTransit ? rideArrival : nil,
                                            arrivals: timeline.steps.map(\.arrival))
        // Picked up on a ride you weren't seen getting on, before its board (or the bus's live
        // times) is in: the timetable can't say it's over, as it may be running late. It waits
        // for the board, for the restore's quiet minute at most.
        if advanced > legIndex, holdsUnseenRide { advanced = legIndex }
        if advanced != legIndex { moveTo(advanced) }
        if !catchingUp, reachedDestination() {
            complete(.arrived)
            return
        }

        if !leg.mode.isTransit {
            if let walk, let position = trustedPosition { walkProgress = PathProgress.locate(position, on: walk.path) }
            if needsRoute { reroute() }
        }
        // Keep the next ride's board live until it has gone.
        if let ride = nextRide ?? (isWaiting ? leg : nil),
           let index = journey.legs.firstIndex(where: { $0.id == ride.id }) {
            let leaves = timeline.steps[index].departure
            if leaves.timeIntervalSince(now) < 45 * 60, now < leaves.addingTimeInterval(5 * 60) {
                Task { [loadBoard] in await loadBoard(ride) }
            }
        }
        retime()
        publish()
    }

    private var holdsUnseenRide: Bool {
        quietSince != nil && leg.mode.isTransit && !boarded && rawBoard(for: leg) == nil
    }

    /// Works the timeline out again from what's happened, where you are and the boards.
    private func retime() {
        let fix = fixSource()
        var seenAtStop: Date?
        if leg.mode.isTransit, !boarded, let fix, let start = leg.start, fix.coordinate.distance(to: start) < 150 {
            seenAtStop = fix.at
        }
        var walkLeft: TimeInterval?
        if !leg.mode.isTransit, let progress = walkProgress { walkLeft = progress.remaining / pace }
        let live = boarded ? yourBus.flatMap(buses.arrival(of:)) : nil
        timeline = TripTimeline.make(journey, log: log, current: legIndex, now: now, seenAtStop: seenAtStop,
                                     liveArrival: live, walkLeft: walkLeft) { rawBoard(for: $0) }
    }

    /// The Live Activity and the alerts follow the timeline, and Go looks for a reason to re-plan.
    private func publish() {
        guard !stopped, !catchingUp else { return }
        considerReplan()
        activity.update(activityState())
        var pending = Set((sentAlerts ?? []).map(\.id))
        if alertsMayBePending {
            alertsMayBePending = false
            pending = Set(["leave"] + journey.legs.indices.map { "getoff.\($0)" })
        }
        let planned = TripAlerts.plan(timeline, from: legIndex, log: log, destination: query.destination.name, now: now,
                                      pending: pending)
        if sentAlerts.map({ TripAlerts.differ($0, planned) }) ?? true {
            sentAlerts = planned
            alerts.schedule(planned)
        }
        persist()
    }

    /// The trip as it would be saved now.
    var saved: SavedTrip {
        var key: String?
        if case .offer(_, let reason) = replan { key = reason.key }
        return SavedTrip(journey: journey, query: query, legIndex: legIndex, log: log, replanWatch: replanWatch,
                         checkedWaits: checkedWaits, arrival: eta, offerKey: key ?? savedOfferKey)
    }

    /// Keeps the trip for a relaunch, when something worth keeping has changed: a step, a
    /// boarding, a leg ended, a Switch, a search or a declined offer (not a walk's seconds).
    private func persist() {
        guard !stopped, let store, !catchingUp else { return }
        let snapshot = saved
        if let lastSaved, lastSaved.sameAs(snapshot) { return }
        lastSaved = snapshot
        saveCount += 1
        store.save(snapshot)
    }

    /// Stamps which departure you got on, once: at `moment`, or now (a tap).
    private func recordBoarding(_ index: Int, at moment: Date? = nil) {
        guard log.boardings[index] == nil, journey.legs.indices.contains(index) else { return }
        let at = moment ?? now
        let departure = TripLog.departure(boardedAt: at, on: rawBoard(for: journey.legs[index]))
        log.boardings[index] = TripLog.Boarding(at: at, departure: departure)
        retime()
    }

    /// Go sees you riding some way along: you got on about that much of the ride ago,
    /// not when it noticed (Go started mid-ride, or the train came up into the open).
    private func boardedBefore(_ index: Int) -> Date {
        let ride = journey.legs[index]
        let length = PathProgress.length(of: ride.path)
        guard length > 0, let position, let progress = PathProgress.locate(position, on: ride.path) else { return now }
        return now.addingTimeInterval(-min(1, progress.distanceAlong / length) * ride.duration)
    }

    private var needsRoute: Bool {
        guard routing == nil, leg.end != nil else { return false }
        guard let last = lastRoute, last.legIndex == legIndex else { return true }
        let wait: TimeInterval = walk == nil ? 30 : 15
        guard now.timeIntervalSince(last.at) > wait else { return false }
        // Re-route once you've strayed, and refresh now and then as fixes settle.
        if let progress = walkProgress, progress.distanceFromPath > Self.offRouteDistance { return true }
        return walk == nil
    }

    private func reroute() {
        guard let end = leg.end else { return }
        let from = trustedPosition ?? leg.start ?? end
        let index = legIndex
        lastRoute = (now, index)
        routing = Task { [weak self, routeWalk] in
            let route = await routeWalk(from, end)
            guard let self, !Task.isCancelled, self.legIndex == index else { return }
            if let route { self.walk = route } else if self.walk == nil { self.walk = WalkRouter.fallback(for: self.leg) }
            if let walk = self.walk, let position = self.trustedPosition {
                self.walkProgress = PathProgress.locate(position, on: walk.path)
            }
            self.routing = nil
        }
    }

    private func moveTo(_ index: Int) {
        if index > legIndex {
            // Moving on finishes the legs between, now.
            // Catching up after Polaris was closed, a leg ended when the timeline had it end, if that's passed.
            for passed in legIndex..<index where log.ended[passed] == nil {
                log.ended[passed] = catchingUp ? min(now, timeline.steps[safe: passed]?.arrival ?? now) : now
            }
        } else {
            log.rewind(to: index)
        }
        routing?.cancel()
        routing = nil
        legIndex = index
        if case .said = replan { replan = .idle }
        yourBusID = nil
        detector.reset()
        walk = nil
        walkProgress = nil
        lastRoute = nil
        if !leg.mode.isTransit { walk = WalkRouter.fallback(for: leg) }
        retime()
        publish()
    }

    // MARK: Re-planning

    /// The boards as loaded, whose planned departure is the plan's (not the timeline's pick).
    private func loadedBoard(_ leg: Leg) -> DepartureBoard? { timetable(leg) }

    /// What the timeline has already done that's worth a line: an earlier or later ride on the
    /// same line, or a long wait (with "nothing quicker" once a search has said so).
    var replanStatus: Replan.Message? {
        guard let status = Replan.status(plan: journey, timeline: timeline, log: log, current: legIndex, board: loadedBoard) else { return nil }
        var checked = false
        if case .longWait(let leg, _) = status { checked = checkedWaits.contains("wait.\(leg)") }
        return Replan.message(status, timeline: timeline, checked: checked)
    }

    /// The offer on screen, in words.
    var offerMessage: Replan.Message? {
        guard case .offer(let offer, let reason) = replan else { return nil }
        return Replan.message(offer, reason: reason, timeline: timeline)
    }

    var offer: Replan.Offer? { if case .offer(let offer, _) = replan { offer } else { nil } }

    /// "Find a faster way" can go now: a stop ahead to ask from, nothing running or offered,
    /// and the trip's cap and spacing allow it.
    var canFindFaster: Bool {
        guard search != nil, replanTask == nil, offer == nil else { return false }
        return Replan.origin(timeline, current: legIndex, boarded: boarded, now: now) != nil && replanWatch.mayAsk(.asked, now: now)
    }

    /// "Find a faster way", tapped.
    func findFaster() {
        now = clock()
        ask(.asked)
    }

    /// Only on an event, never on the clock: the rides ahead changed, you boarded, or a leg ended.
    private func considerReplan() {
        withdrawStaleOffer()
        let event = replanEvent
        if let since = quietSince {
            // What the restored boards change is the restore's doing, not an event.
            let boardsIn = journey.legs.filter { quietLegs.contains($0.id) }.allSatisfy { timetable($0) != nil }
            if boardsIn || now.timeIntervalSince(since) <= 60 {
                if boardsIn { quietSince = nil }
                lastReplanEvent = event
                return
            }
            // A board never came: the quiet is over, and this event is looked at as any other.
            quietSince = nil
        }
        guard event != lastReplanEvent else { return }
        lastReplanEvent = event
        guard search != nil, replanTask == nil, offer == nil,
              let reason = Replan.reason(plan: journey, timeline: timeline, log: log, current: legIndex,
                                         missedRide: missedRide, board: loadedBoard) else { return }
        ask(reason)
    }

    private var replanEvent: [String] {
        Replan.fingerprint(timeline, from: legIndex) + ["leg \(legIndex)", "on \(log.boardings.count)", "off \(log.ended.count)"]
    }

    private func ask(_ reason: Replan.Reason) {
        guard let search, replanTask == nil,
              let origin = Replan.origin(timeline, current: legIndex, boarded: boarded, now: now),
              replanWatch.mayAsk(reason, now: now) else { return }
        // No way to the internet (underground): send nothing; the next stop is the next event.
        guard isOnline() else {
            if reason == .asked {
                replan = .said(Replan.Message(title: "No signal", detail: Replan.noSignal(at: origin), short: "No signal", compact: "No signal"))
            }
            return
        }
        if reason == .asked { replan = .looking(origin) }
        let query = origin.query(to: self.query.destination)
        let watch = replanWatch
        replanTask = Task { [weak self] in
            let answer = await search(query, watch)
            guard !Task.isCancelled else { return }
            self?.finish(reason, from: origin, answer: answer)
        }
    }

    private func finish(_ reason: Replan.Reason, from origin: Replan.Origin, answer: ReplanAnswer) {
        replanTask = nil
        // What was asked counts against the trip's cap after a relaunch too.
        defer { persist() }
        now = clock()
        replanWatch.asked(reason, now: now, usedGoogle: answer.usedGoogle, answered: answer.answered)
        guard answer.answered else {
            replan = reason == .asked
                ? .said(Replan.Message(title: "No signal", detail: Replan.noSignal(at: origin), short: "No signal", compact: "No signal"))
                : .idle
            return
        }
        // Judged against the trip as it is now, from that stop, if it's still ahead and you
        // haven't got on the ride there since (an offer never replaces the ride you're on).
        if legIndex <= origin.resumeAt, log.boardings[origin.resumeAt] == nil,
           var offer = Replan.offer(timeline, from: origin, candidates: answer.journeys) {
            offer.statusChecked = answer.statusChecked
            replan = .offer(offer, reason: reason)
            savedOfferKey = nil
            alerts.offer(Replan.message(offer, reason: reason, timeline: timeline))
        } else {
            if case .longWait = reason { checkedWaits.insert(reason.key) }
            replan = reason == .asked ? .said(Replan.nothingBetter(timeline, from: origin)) : .idle
        }
        activity.update(activityState())
    }

    /// Still takeable: you haven't passed its stop or got on the ride it would replace, and its
    /// first ride hasn't left.
    private func stillGood(_ offer: Replan.Offer) -> Bool {
        let first = offer.journey.transitLegs.first?.departure ?? offer.journey.departure
        return legIndex <= offer.origin.resumeAt && log.boardings[offer.origin.resumeAt] == nil
            && now <= first.addingTimeInterval(30)
    }

    /// An offer goes once it's no longer takeable.
    private func withdrawStaleOffer() {
        guard let offer, !stillGood(offer) else { return }
        replan = .idle
        alerts.offer(nil)
    }

    /// Switch: carry on by the new way from its stop. The legs done stay, with the log; the
    /// alerts, the Live Activity and the timeline follow the new journey.
    func acceptOffer() {
        guard let offer else {
            // Tapped on the notification of an offer from before Polaris closed: it wasn't kept.
            if savedOfferKey != nil {
                savedOfferKey = nil
                replan = .said(.offerGone)
                activity.update(activityState())
                persist()
            }
            return
        }
        // Tapped on a notification, the app may have been asleep since the offer: look again.
        now = clock()
        guard stillGood(offer) else {
            alerts.offer(nil)
            replan = .said(.offerGone)
            activity.update(activityState())
            return
        }
        journey = Replan.splice(timeline, plan: journey, offer: offer)
        replanWatch.forget(from: offer.origin.resumeAt)
        replan = .idle
        alerts.offer(nil)
        checkedWaits = []
        chosenBus = nil
        detector.reset()
        legIndex = min(legIndex, journey.legs.count - 1)
        if !leg.mode.isTransit {
            walk = WalkRouter.fallback(for: leg)
            walkProgress = nil
            lastRoute = nil
        }
        // The new rides' boards, once each (only the next ride's refreshes after).
        let later = journey.legs.dropFirst(offer.origin.resumeAt).filter { $0.mode.isTransit && timetable($0) == nil }
        Task { [loadBoard] in for ride in later { await loadBoard(ride) } }
        retime()
        publish()
    }

    /// Keep my route: the offer goes, and that reason isn't asked again this trip.
    func keepRoute() {
        guard case .offer(_, let reason) = replan else {
            // Tapped on the notification of an offer from before Polaris closed: decline its reason.
            if let key = savedOfferKey {
                savedOfferKey = nil
                replanWatch.declined(key: key)
                persist()
            }
            return
        }
        replanWatch.declined(reason)
        replan = .idle
        alerts.offer(nil)
        activity.update(activityState())
        persist()
    }

    // MARK: Live Activity

    func activityState() -> TripActivityAttributes.ContentState {
        let leg = leg
        let pill = { (leg: Leg) in LinePill.shortName(leg.line ?? leg.mode.label) }
        // To the minute (as the app's clock shows it), so a walk's moving estimate doesn't
        // push an update every tick.
        let arrival = Date(timeIntervalSinceReferenceDate: (eta.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        var state = TripActivityAttributes.ContentState(
            symbol: leg.mode.symbol, title: "", detail: "", lineName: nil, lineColor: nil,
            countdownLabel: "Arrive", countdownTo: arrival, arrival: arrival,
            step: legIndex + 1, stepCount: journey.legs.count)
        if leg.mode.isTransit {
            state.lineName = pill(leg)
            state.lineColor = leg.lineColor.map(\.hex)
            let leaves = rideDeparture
            if isWaiting {
                state.title = "\(pill(leg)) from \(leg.fromName)"
                state.detail = [leg.headsign.map { "towards \($0)" }, leg.platform.map { leg.standing(at: $0) }]
                    .compactMap { $0 }.joined(separator: " · ")
                state.countdownLabel = "Leaves"
                state.countdownTo = leaves
                Self.addMissIt(ifMissed, ride: leg, to: &state)
            } else {
                state.title = "\(pill(leg)) to \(leg.toName)"
                if let yours = yourDeparture {
                    state.detail = "On the \(TripActivityAttributes.ContentState.clock(yours.expected)), get off at \(leg.toName)"
                } else {
                    state.detail = leg.stopCount.map { "\($0) stop\($0 == 1 ? "" : "s"), get off at \(leg.toName)" } ?? "Get off at \(leg.toName)"
                }
                state.countdownLabel = "Get off"
                state.countdownTo = rideArrival
            }
        } else if let ride = nextRide {
            state.title = "Walk to \(ride.fromName)"
            state.detail = "\(pill(ride))" + (ride.platform.map { " from \(ride.standing(at: $0))" } ?? " towards \(ride.headsign ?? ride.toName)")
            state.lineName = pill(ride)
            state.lineColor = ride.lineColor.map(\.hex)
            state.countdownLabel = "Leaves"
            state.countdownTo = nextRideDeparture ?? ride.departure
            Self.addMissIt(ifMissed, ride: ride, to: &state)
        } else {
            state.title = "Walk to \(query.destination.name)"
            state.detail = remainingWalk.map { Self.distanceText($0) } ?? leg.duration.minutesText
        }
        // A faster way, or a long wait for the next ride, says so in place of the detail.
        if let offer = offerMessage {
            state.detail = offer.short
        } else if let status = Replan.status(plan: journey, timeline: timeline, log: log, current: legIndex, board: loadedBoard),
                  case .longWait(let index, _) = status, index == upcomingRide, let words = replanStatus {
            state.detail = words.short
        }
        return state
    }

    /// What to catch if you miss the ride, and what that does to your arrival.
    static func addMissIt(_ ifMissed: IfMissed?, ride: Leg, to state: inout TripActivityAttributes.ContentState) {
        guard let ifMissed else { return }
        let line = LinePill.shortName(ifMissed.next.line)
        state.nextDeparture = ifMissed.next.expected
        state.nextLine = line.lowercased() == LinePill.shortName(ride.line ?? "").lowercased() ? nil : line
        state.missCost = ifMissed.cost
        state.missCostIsFloor = ifMissed.costIsFloor
        state.connection = ifMissed.connection.map {
            "\(TripActivityAttributes.ContentState.clock($0.departure)) \(LinePill.shortName($0.line ?? $0.mode.label))"
        }
        state.losesConnection = ifMissed.losesConnection
    }

    static func distanceText(_ metres: Double) -> String {
        metres < 1000 ? "\(Int((metres / 10).rounded()) * 10) m" : String(format: "%.1f km", metres / 1000)
    }
}

extension RGB {
    var hex: String {
        String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
