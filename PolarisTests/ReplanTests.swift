import Foundation
import Testing
@testable import Polaris

/// Re-planning during Go: when to look, where from, what counts as better, and how often.
/// The sample Bakerloo trip with a 277 at the end; no network, boards and candidates by hand.
struct ReplanTests {
    typealias T = LiveTripTests
    static func at(_ clock: String) -> Date { T.at(clock) }

    static let busStop = Coordinate(latitude: 51.5040, longitude: -0.0175)
    static let crossharbour = Coordinate(latitude: 51.4957, longitude: -0.0144)
    static let island = Coordinate(latitude: 51.4950, longitude: -0.0150)
    static let heronQuays = Coordinate(latitude: 51.5027, longitude: -0.0215)

    /// The Bakerloo trip, but off the Jubilee it's two minutes to the stop and the 07:20 277
    /// (a three-minute wait) to Crossharbour, then a walk: there at 07:34.
    static var toIsland: Journey {
        var journey = T.bakerloo
        let walk = Leg(mode: .walk, fromName: "Canary Wharf", toName: "Canary Wharf Station", departure: at("07:15:00"), arrival: at("07:17:00"),
                       path: [T.canaryWharf, busStop])
        let bus = Leg(mode: .bus, line: "277", headsign: "Crossharbour", fromName: "Canary Wharf Station", toName: "Crossharbour",
                      departure: at("07:20:00"), arrival: at("07:30:00"), stopCount: 6, path: [busStop, crossharbour], platform: "C")
        let last = Leg(mode: .walk, fromName: "Crossharbour", toName: "Island", departure: at("07:30:00"), arrival: at("07:34:00"),
                       path: [crossharbour, island])
        journey.legs = Array(journey.legs.prefix(4)) + [walk, bus, last]
        journey.arrival = at("07:34:00")
        return journey
    }

    /// The 277 every 20 minutes, ten minutes to Crossharbour.
    static func busBoard(_ leg: Leg, planned: String = "07:20:00", cancelled: Bool = false) -> DepartureBoard {
        let departures = ["07:00:00", "07:20:00", "07:40:00", "08:00:00"].map { time in
            Departure(id: "277-\(time)", line: "277", mode: .bus, headsign: "Crossharbour", stopName: leg.fromName,
                      stopCoordinate: leg.start!, scheduled: at(time), expected: at(time), isRealtime: true,
                      isCancelled: cancelled && time == planned, arrivalThere: at(time).addingTimeInterval(600))
        }
        return DepartureBoard(stopName: leg.fromName, departures: departures, plannedID: "277-\(planned)")
    }

    static func boards(_ journey: Journey, cancelled: Bool = false) -> [UUID: DepartureBoard] {
        var boards = T.bakerlooBoards(journey)
        boards[journey.legs[5].id] = busBoard(journey.legs[5], cancelled: cancelled)
        return boards
    }

    /// A planner's journey from `from` at the given times, one ride per line given.
    static func candidate(_ rides: [(mode: LegMode, line: String, from: String, to: String, leaves: String, arrives: String)],
                          start: String, end: String, origin: String = "Baker Street", notices: [ServiceNotice] = []) -> Journey {
        let legs = rides.map { ride in
            Leg(mode: ride.mode, line: ride.line, fromName: ride.from, toName: ride.to, departure: at(ride.leaves), arrival: at(ride.arrives),
                path: [T.bakerStreet, heronQuays])
        }
        var journey = Journey(departure: at(start), arrival: at(end), legs: legs, sources: [SourceTag(provider: .tfl, variant: "Fastest")])
        journey.notices = notices
        return journey
    }

    /// On the 06:26 Bakerloo instead of the 06:41 (a tap at 06:26:20): out at Baker Street
    /// 06:34, the 06:39 Jubilee, at the 277's stop by 07:01, a minute after the 07:00 left.
    @MainActor static func earlyDrive() -> T.Drive {
        let journey = toIsland
        let drive = T.Drive(journey, at: at("06:22:00"), boards: boards(journey), fix: T.paddington)
        drive.tick("06:22:00", at: T.paddington)
        drive.clock = at("06:26:20")
        drive.trip.take(.boarded(journey.legs[1]))
        return drive
    }

    // MARK: When to look

    /// Early by two trains: the Jubilee moves up on its own (the timeline's job, said plainly),
    /// but the 277 doesn't, so the three-minute wait becomes nineteen. That's worth a look.
    @MainActor @Test func earlyIntoALongWaitIsAReason() throws {
        let drive = Self.earlyDrive()
        let trip = drive.trip!
        let plan = trip.journey
        #expect(trip.timeline.steps[3].service?.scheduled == Self.at("06:39:00"))
        #expect(trip.timeline.steps[5].departure == Self.at("07:20:00"))
        #expect(trip.eta == Self.at("07:34:00"))
        let raw = { (leg: Leg) in drive.boards[leg.id] }

        let reason = Replan.reason(plan: plan, timeline: trip.timeline, log: trip.log, current: trip.legIndex,
                                   missedRide: trip.missedRide, board: raw)
        #expect(reason == .longWait(leg: 5, wait: 19 * 60))
        #expect(reason?.key == "wait.5")

        let status = try #require(Replan.status(plan: plan, timeline: trip.timeline, log: trip.log, current: trip.legIndex, board: raw))
        #expect(status == .longWait(leg: 5, wait: 19 * 60))
        let words = Replan.message(status, timeline: trip.timeline, checked: true)
        #expect(words.title == "You're early: 19 min wait for the 277")
        #expect(words.detail == "At Canary Wharf Station, it leaves 07:20. Nothing quicker from there.")
        #expect(words.short == "19 min wait for the 07:20 277")
    }

    /// Early onto the plain Bakerloo trip: the earlier Jubilee gets you in 12 minutes sooner.
    /// Nothing to search for, but worth saying.
    @MainActor @Test func anEarlierRideOnTheSameLineIsSaidNotSearched() throws {
        let journey = T.bakerloo
        let drive = T.Drive(journey, at: Self.at("06:28:00"), boards: T.bakerlooBoards(journey), fix: T.paddington)
        let trip = drive.trip!
        drive.tick("06:28:00", at: T.paddington)
        drive.clock = Self.at("06:30:20")
        trip.take(.boarded(journey.legs[1]))
        let raw = { (leg: Leg) in drive.boards[leg.id] }
        #expect(Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: 1, missedRide: false, board: raw) == nil)
        let status = try #require(Replan.status(plan: journey, timeline: trip.timeline, log: trip.log, current: 1, board: raw))
        guard case .otherRide(let leg, let service, let by) = status else { Issue.record("not another ride"); return }
        #expect(leg == 3 && service.scheduled == Self.at("06:43:00") && by == -12 * 60)
        let words = Replan.message(status, timeline: trip.timeline, checked: false)
        #expect(words.title == "You're early: the 06:43 Jubilee")
        #expect(words.detail == "Arrive 07:08, 12 min sooner.")
        #expect(words.short == "Early: 06:43 Jubilee, arrive 07:08")
    }

    /// Missing a tube that runs every few minutes costs four: say nothing.
    @MainActor @Test func aSmallSlipStaysSilent() throws {
        let journey = T.bakerloo
        let drive = T.Drive(journey, at: Self.at("06:38:00"), boards: T.bakerlooBoards(journey), fix: T.paddington)
        drive.tick("06:38:00", at: T.paddington)
        drive.tick("06:42:30", at: T.paddington)
        let trip = drive.trip!
        #expect(trip.missedRide && trip.eta == Self.at("07:24:00"))
        #expect(Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: trip.legIndex,
                              missedRide: trip.missedRide) { drive.boards[$0.id] } == nil)
        // But it's said: the Jubilee you'll now make, and what it does to the arrival.
        let status = try #require(Replan.status(plan: journey, timeline: trip.timeline, log: trip.log, current: trip.legIndex) { drive.boards[$0.id] })
        let words = Replan.message(status, timeline: trip.timeline, checked: false)
        #expect(words.title == "Running late: the 06:59 Jubilee")
        #expect(words.detail == "Arrive 07:24, 4 min later.")
        #expect(words.short == "Late: 06:59 Jubilee, arrive 07:24")
    }

    /// The other case: early enough for the bus before the planned one. The timeline takes it
    /// on its own, and the line names the bus, which sets the arrival, not the Jubilee before it.
    @MainActor @Test func earlyEnoughForTheEarlierBusIsSaid() throws {
        let journey = Self.toIsland
        let drive = T.Drive(journey, at: Self.at("06:20:00"), boards: Self.boards(journey), fix: T.paddington)
        let trip = drive.trip!
        drive.tick("06:20:00", at: T.paddington)
        drive.clock = Self.at("06:22:20")
        trip.take(.boarded(journey.legs[1]))
        // Off 06:30, the 06:35 Jubilee, Canary Wharf 06:55, the stop 06:57: the 07:00 277, there 07:14.
        #expect(trip.timeline.steps[5].service?.scheduled == Self.at("07:00:00"))
        #expect(trip.eta == Self.at("07:14:00"))
        let raw = { (leg: Leg) in drive.boards[leg.id] }
        #expect(Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: 1, missedRide: false, board: raw) == nil)
        let status = try #require(Replan.status(plan: journey, timeline: trip.timeline, log: trip.log, current: 1, board: raw))
        let words = Replan.message(status, timeline: trip.timeline, checked: false)
        #expect(words.title == "You're early: the 07:00 277")
        #expect(words.detail == "Arrive 07:14, 20 min sooner.")
    }

    /// A cancelled tube on a line every four minutes costs four: not worth a search.
    @MainActor @Test func aCancelledTrainOnAFrequentLineStaysSilent() {
        let journey = T.bakerloo
        var boards = T.bakerlooBoards(journey)
        let jubilee = journey.legs[3].id
        boards[jubilee]!.departures = boards[jubilee]!.departures.map { var d = $0; d.isCancelled = d.id == "Jubilee-06:55:00"; return d }
        let drive = T.Drive(journey, at: Self.at("06:30:00"), boards: boards, fix: T.start)
        drive.tick("06:30:00", at: T.start)
        let trip = drive.trip!
        #expect(trip.eta == Self.at("07:24:00"))
        #expect(Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: trip.legIndex,
                              missedRide: false) { drive.boards[$0.id] } == nil)
    }

    /// Missing the Bakerloo with a 277 at the end loses the bus too: twenty minutes late.
    @MainActor @Test func aMissThatLosesTheBusIsAReason() {
        let journey = Self.toIsland
        let drive = T.Drive(journey, at: Self.at("06:38:00"), boards: Self.boards(journey), fix: T.paddington)
        drive.tick("06:38:00", at: T.paddington)
        drive.tick("06:42:30", at: T.paddington)
        let trip = drive.trip!
        #expect(trip.eta == Self.at("07:54:00"))
        #expect(Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: trip.legIndex,
                              missedRide: trip.missedRide) { drive.boards[$0.id] } == .missed(leg: 1, late: 20 * 60))
    }

    /// Held after getting off, not missed at the stop: the lost bus is the reason.
    @MainActor @Test func aLostConnectionLaterOnIsAReason() {
        let journey = Self.toIsland
        let drive = T.Drive(journey, at: Self.at("06:38:00"), boards: Self.boards(journey), fix: T.paddington)
        let trip = drive.trip!
        drive.tick("06:38:00", at: T.paddington)
        drive.clock = Self.at("06:41:00")
        trip.take(.boarded(journey.legs[1]))
        drive.clock = Self.at("06:53:30")
        trip.take(.gotOff(journey.legs[1]))
        // At the Jubilee by 06:56:30: the 06:59, Canary Wharf 07:19, the stop 07:21, the 07:40.
        #expect(trip.eta == Self.at("07:54:00"))
        let reason = Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: trip.legIndex,
                                   missedRide: false) { drive.boards[$0.id] }
        #expect(reason == .lostConnection(leg: 3, late: 20 * 60))
    }

    /// The planned 277 cancelled on its board.
    @MainActor @Test func aCancelledRideAheadIsAReason() {
        let journey = Self.toIsland
        let drive = T.Drive(journey, at: Self.at("06:30:00"), boards: Self.boards(journey, cancelled: true), fix: T.start)
        drive.tick("06:30:00", at: T.start)
        let trip = drive.trip!
        #expect(Replan.reason(plan: journey, timeline: trip.timeline, log: trip.log, current: trip.legIndex,
                              missedRide: false) { drive.boards[$0.id] } == .cancelled(leg: 5))
    }

    /// Reaching a change before its board's window starts, the board can't show the earlier
    /// buses, so the long wait it seems to show is no evidence: silent.
    @Test func aWaitBeforeTheBoardStartsIsNoEvidence() {
        let plan = Self.toIsland
        var timeline = TripTimeline.plan(plan)
        let board = Self.busBoard(plan.legs[5])
        // At the stop by 06:58, before the window (07:00) opens; the timeline still has the 07:20.
        timeline.steps[4].arrival = Self.at("06:58:00")
        timeline.steps[5].service = board.planned
        #expect(Replan.knownWait(plan: plan, timeline: timeline, at: 5, board: board) == nil)
        timeline.steps[4].arrival = Self.at("07:01:00")
        #expect(Replan.knownWait(plan: plan, timeline: timeline, at: 5, board: board) == TimeInterval(19 * 60))
        // And past what the board knows, a guess: no evidence either.
        timeline.steps[5].isEstimate = true
        #expect(Replan.knownWait(plan: plan, timeline: timeline, at: 5, board: board) == nil)
    }

    /// Go looks again only when the rides ahead change, not as a walk's estimate drifts.
    @Test func theFingerprintIgnoresDriftButNotANewRide() {
        let plan = Self.toIsland
        var timeline = TripTimeline.plan(plan)
        let before = Replan.fingerprint(timeline, from: 0)
        timeline.steps[0].arrival = timeline.steps[0].arrival.addingTimeInterval(20)
        #expect(Replan.fingerprint(timeline, from: 0) == before)
        timeline.steps[5].service = Self.busBoard(plan.legs[5], planned: "07:40:00").planned
        #expect(Replan.fingerprint(timeline, from: 0) != before)
    }

    // MARK: Where from

    @MainActor @Test func asksFromTheNextStopAtTheTimelinesTime() throws {
        let drive = Self.earlyDrive()
        let trip = drive.trip!
        // On the Bakerloo (no fix underground): from Baker Street when it gets in, not Paddington.
        let riding = try #require(Replan.origin(trip.timeline, current: 1, boarded: true, now: trip.now))
        #expect(riding.resumeAt == 2 && riding.name == "Baker Street" && riding.time == Self.at("06:34:00"))
        #expect(riding.coordinate == T.bakerStreet)
        let query = riding.query(to: Place(name: "Island", coordinate: Self.island))
        #expect(query.time == .departAt(Self.at("06:34:00")))
        // Walking the change: from the Jubilee's platform when the walk ends.
        let walking = try #require(Replan.origin(trip.timeline, current: 2, boarded: false, now: Self.at("06:35:00")))
        #expect(walking.resumeAt == 3 && walking.name == "Baker Street" && walking.time == Self.at("06:37:00"))
        // Waiting at a stop: from there, now.
        let waiting = try #require(Replan.origin(trip.timeline, current: 5, boarded: false, now: Self.at("07:02:00")))
        #expect(waiting.resumeAt == 5 && waiting.name == "Canary Wharf Station" && waiting.time == Self.at("07:02:00"))
        // On the last ride, only a walk is left from its stop: nothing to re-plan.
        #expect(Replan.origin(trip.timeline, current: 5, boarded: true, now: Self.at("07:21:00")) == nil)
    }

    // MARK: Is there a better way

    /// From Baker Street at 06:34 with 07:34 to beat, a new way needs 9 minutes (15% of the hour
    /// to go, more than the 5-minute floor). The DLR way gives 21; the rest don't qualify.
    @MainActor @Test func offersOnlyAClearlyBetterUnflaggedWay() throws {
        let drive = Self.earlyDrive()
        let trip = drive.trip!
        let origin = try #require(Replan.origin(trip.timeline, current: 1, boarded: true, now: trip.now))
        let dlr = Self.candidate([(.tube, "Jubilee", "Baker Street", "Canary Wharf", "06:39:00", "06:59:00"),
                                  (.dlr, "DLR", "Heron Quays", "Crossharbour", "07:05:00", "07:10:00")],
                                 start: "06:34:00", end: "07:13:00")
        let sameLines = Self.candidate([(.tube, "Jubilee", "Baker Street", "Canary Wharf", "06:39:00", "06:59:00"),
                                        (.bus, "277", "Canary Wharf Station", "Crossharbour", "07:00:00", "07:10:00")],
                                       start: "06:34:00", end: "07:05:00")
        let closed = Self.candidate([(.elizabeth, "Elizabeth line", "Bond Street", "Canary Wharf", "06:40:00", "06:55:00")],
                                    start: "06:34:00", end: "07:00:00",
                                    notices: [ServiceNotice(title: "Canary Wharf part closed", detail: "", severity: .closed, source: .tfl, leg: UUID())])
        let gone = Self.candidate([(.tube, "Jubilee", "Baker Street", "Canary Wharf", "06:31:00", "06:51:00")],
                                  start: "06:30:00", end: "06:58:00")
        let busy = Self.candidate([(.tube, "Jubilee", "Baker Street", "Waterloo", "06:39:00", "06:46:00"),
                                   (.rail, "Southeastern", "Waterloo East", "Greenwich", "06:52:00", "07:02:00"),
                                   (.dlr, "DLR", "Cutty Sark", "Crossharbour", "07:10:00", "07:14:00")],
                                  start: "06:34:00", end: "07:27:00")
        let slight = Self.candidate([(.tube, "Metropolitan", "Baker Street", "Aldgate", "06:38:00", "06:52:00"),
                                     (.dlr, "DLR", "Tower Gateway", "Crossharbour", "07:00:00", "07:17:00")],
                                    start: "06:34:00", end: "07:27:00")

        let offer = try #require(Replan.offer(trip.timeline, from: origin, candidates: [sameLines, closed, gone, busy, slight, dlr]))
        #expect(offer.journey.id == dlr.id)
        #expect(offer.gain == 21 * 60)
        #expect(Replan.offer(trip.timeline, from: origin, candidates: [sameLines, closed, gone, busy, slight]) == nil)

        let reason = Replan.Reason.longWait(leg: 5, wait: 19 * 60)
        let words = Replan.message(offer, reason: reason, timeline: trip.timeline)
        #expect(words.title == "Faster way from Baker Street")
        #expect(words.detail == "Take the Jubilee, then the DLR to Crossharbour: arrive 07:13, 21 min sooner than waiting 19 min for the 277.")
        #expect(words.short == "Faster way: 21 min sooner, arrive 07:13")

        // The same offer for the other reasons, and the other things Go can say about asking.
        #expect(Replan.message(offer, reason: .lostConnection(leg: 5, late: 600), timeline: trip.timeline).detail
                == "Take the Jubilee, then the DLR to Crossharbour: arrive 07:13, 21 min sooner than 07:34 this way.")
        #expect(Replan.message(offer, reason: .cancelled(leg: 5), timeline: trip.timeline).detail
                == "Take the Jubilee, then the DLR to Crossharbour: arrive 07:13, 21 min sooner, with the planned 277 cancelled.")
        #expect(Replan.message(offer, reason: .asked, timeline: trip.timeline).detail
                == "Take the Jubilee, then the DLR to Crossharbour: arrive 07:13, 21 min sooner.")
        let none = Replan.nothingBetter(trip.timeline, from: origin)
        #expect(none.title == "Your route is still the quickest")
        #expect(none.detail == "Nothing gets there sooner from Baker Street than 07:34.")
        #expect(Replan.looking(from: origin) == "Looking for a faster way from Baker Street")
        #expect(Replan.noSignal(at: origin) == "No signal here. Beeline Home will look again at Baker Street.")
    }

    /// Taking it keeps the legs already done, with their ids (the log points at them), and
    /// the journey's id (the sheet follows it); the rest is the new way.
    @MainActor @Test func takingTheOfferKeepsWhatsDone() throws {
        let drive = Self.earlyDrive()
        let trip = drive.trip!
        let origin = try #require(Replan.origin(trip.timeline, current: 1, boarded: true, now: trip.now))
        let dlr = Self.candidate([(.tube, "Jubilee", "Baker Street", "Canary Wharf", "06:39:00", "06:59:00"),
                                  (.dlr, "DLR", "Heron Quays", "Crossharbour", "07:05:00", "07:10:00")],
                                 start: "06:34:00", end: "07:13:00")
        let offer = try #require(Replan.offer(trip.timeline, from: origin, candidates: [dlr]))
        let spliced = Replan.splice(trip.timeline, plan: trip.journey, offer: offer)
        #expect(spliced.id == trip.journey.id)
        #expect(spliced.legs.prefix(2).map(\.id) == trip.journey.legs.prefix(2).map(\.id))
        #expect(spliced.legs[1].departure == Self.at("06:26:00"))
        #expect(spliced.legs.dropFirst(2).map(\.id) == dlr.legs.map(\.id))
        #expect(spliced.arrival == Self.at("07:13:00"))
        #expect(spliced.departure == trip.timeline.journey.departure)
    }

    // MARK: How often

    @Test func asksOncePerReasonAndAFewTimesPerTrip() {
        var watch = Replan.Watch()
        let wait = Replan.Reason.longWait(leg: 5, wait: 19 * 60)
        let t0 = Self.at("06:30:00")
        #expect(watch.mayAsk(wait, now: t0))
        watch.asked(wait, now: t0, usedGoogle: true, answered: true)
        // The same reason, even with a new wait, doesn't ask again; nor anything within 4 minutes.
        #expect(!watch.mayAsk(.longWait(leg: 5, wait: 22 * 60), now: t0.addingTimeInterval(600)))
        #expect(!watch.mayAsk(.missed(leg: 1, late: 600), now: t0.addingTimeInterval(120)))
        #expect(watch.mayAsk(.missed(leg: 1, late: 600), now: t0.addingTimeInterval(300)))
        // Tapped: allowed again for the same leg's reason, but not inside the spacing.
        #expect(watch.mayAsk(.asked, now: t0.addingTimeInterval(300)))
        watch.asked(.asked, now: t0.addingTimeInterval(300), usedGoogle: false, answered: true)
        watch.asked(.cancelled(leg: 3), now: t0.addingTimeInterval(600), usedGoogle: true, answered: true)
        // Three answered: that's the trip's lot, tapped or not.
        #expect(!watch.mayAsk(.asked, now: t0.addingTimeInterval(1200)))
        #expect(watch.googleRequests == 2)
    }

    @Test func noSignalLeavesTheReasonOpenButCannotLoop() {
        var watch = Replan.Watch()
        let late = Replan.Reason.lostConnection(leg: 3, late: 900)
        let t0 = Self.at("06:50:00")
        watch.asked(late, now: t0, usedGoogle: false, answered: false)
        #expect(watch.mayAsk(late, now: t0.addingTimeInterval(300)))
        watch.asked(late, now: t0.addingTimeInterval(300), usedGoogle: false, answered: false)
        #expect(!watch.mayAsk(late, now: t0.addingTimeInterval(900)))
        #expect(watch.searches == 0)
        // Back in signal, a tap still asks.
        #expect(watch.mayAsk(.asked, now: t0.addingTimeInterval(900)))
    }

    /// Google three times a trip at most, failed sends included.
    @Test func googleAtMostThreeTimesATrip() {
        var watch = Replan.Watch()
        let now = Self.at("06:30:00")
        watch.asked(.missed(leg: 1, late: 600), now: now, usedGoogle: true, answered: false)
        watch.asked(.longWait(leg: 5, wait: 900), now: now, usedGoogle: true, answered: true)
        watch.asked(.asked, now: now, usedGoogle: true, answered: true)
        #expect(!watch.mayUseGoogle)
        #expect(Replan.sources(enabled: [.google, .tfl, .transitous], hasGoogleKey: true, allowance: GoogleAllowance(), watch: watch, now: now)
                == [.tfl, .transitous])
    }

    @Test func keepingMyRouteIsntAskedAgain() {
        var watch = Replan.Watch()
        let wait = Replan.Reason.longWait(leg: 5, wait: 19 * 60)
        watch.declined(wait)
        #expect(!watch.mayAsk(wait, now: Self.at("07:00:00")))
        #expect(watch.mayAsk(.asked, now: Self.at("07:00:00")))
    }

    /// Google only while the month has room, counted in Google's own month (Pacific time).
    @Test func googleOnlyInsideTheFreeAllowance() {
        let now = Self.at("06:30:00")
        var allowance = GoogleAllowance()
        allowance.spend(899, now: now)
        let enabled: Set<ProviderID> = [.google, .tfl, .transitous]
        #expect(Replan.sources(enabled: enabled, hasGoogleKey: true, allowance: allowance, now: now) == [.google, .tfl, .transitous])
        allowance.spend(1, now: now)
        #expect(allowance.usedThisMonth(now: now) == 900)
        #expect(Replan.sources(enabled: enabled, hasGoogleKey: true, allowance: allowance, now: now) == [.tfl, .transitous])
        #expect(Replan.sources(enabled: [.google, .transitous], hasGoogleKey: false, allowance: GoogleAllowance(), now: now) == [.transitous])
        // 05:00 on 1 December in London is still 30 November in California: same month.
        let stillNovember = Time.iso("2026-12-01T05:00:00Z")!
        #expect(allowance.usedThisMonth(now: stillNovember) == 900)
        let december = Time.iso("2026-12-01T09:00:00Z")!
        #expect(allowance.usedThisMonth(now: december) == 0)
        #expect(Replan.sources(enabled: enabled, hasGoogleKey: true, allowance: allowance, now: december).first == .google)
    }

    // MARK: In Go

    /// A planner by hand: every query it's asked, and the answer it gives. No network.
    @MainActor final class Planner {
        var queries: [JourneyQuery] = []
        var answer: ReplanAnswer
        init(_ journeys: [Journey], answered: Bool = true) { answer = ReplanAnswer(journeys: journeys, answered: answered, usedGoogle: answered) }
        var search: ReplanSearch.Search {
            { [self] query, _ in
                queries.append(query)
                return answer
            }
        }
    }

    /// From Baker Street: the Jubilee, four minutes' walk to Heron Quays, the DLR, three minutes' walk.
    static func dlrWay(leaving start: String = "06:34:00") -> Journey {
        let legs = [
            Leg(mode: .tube, line: "Jubilee", fromName: "Baker Street", toName: "Canary Wharf", departure: at("06:39:00"), arrival: at("06:59:00"),
                path: [T.jubileePlatform, T.canaryWharf]),
            Leg(mode: .walk, fromName: "Canary Wharf", toName: "Heron Quays", departure: at("06:59:00"), arrival: at("07:03:00"),
                path: [T.canaryWharf, heronQuays]),
            Leg(mode: .dlr, line: "DLR", fromName: "Heron Quays", toName: "Crossharbour", departure: at("07:05:00"), arrival: at("07:10:00"),
                path: [heronQuays, crossharbour]),
            Leg(mode: .walk, fromName: "Crossharbour", toName: "Island", departure: at("07:10:00"), arrival: at("07:13:00"),
                path: [crossharbour, island]),
        ]
        return Journey(departure: at(start), arrival: at("07:13:00"), legs: legs, sources: [SourceTag(provider: .transitous, variant: "Fastest")])
    }

    static var dlr: Journey { dlrWay() }

    /// Early onto the Bakerloo with a planner that knows the DLR way.
    @MainActor static func early(with planner: Planner) async -> T.Drive {
        let journey = toIsland
        let drive = T.Drive(journey, at: at("06:22:00"), boards: boards(journey), fix: T.paddington, search: planner.search)
        drive.tick("06:22:00", at: T.paddington)
        drive.clock = at("06:26:20")
        drive.trip.take(.boarded(journey.legs[1]))
        await drive.trip.replanTask?.value
        return drive
    }

    /// The tap that says you're on the early Bakerloo is the event: Go asks once, from Baker
    /// Street when it gets in, and offers the DLR way in the sheet, the notification and the
    /// Live Activity. Ticks that change nothing don't ask again.
    @MainActor @Test func goAsksOnceAndOffersTheFasterWay() async throws {
        let planner = Planner([Self.dlr])
        let drive = await Self.early(with: planner)
        let trip = drive.trip!
        #expect(planner.queries.count == 1)
        let query = try #require(planner.queries.first)
        #expect(query.origin.name == "Baker Street" && query.time == .departAt(Self.at("06:34:00")))
        #expect(query.destination.name == "One Canada Square")
        let offer = try #require(trip.offer)
        #expect(offer.gain == 21 * 60)
        #expect(drive.alerts.offered?.title == "Faster way from Baker Street")
        #expect(trip.offerMessage?.compact == "21 min sooner · 07:13")
        #expect(trip.activityState().detail == "Faster way: 21 min sooner, arrive 07:13")
        drive.tick("06:27:00")
        drive.tick("06:28:00")
        drive.tick("06:29:30")
        await trip.replanTask?.value
        #expect(planner.queries.count == 1)
        #expect(trip.offer != nil)
    }

    /// Switch: the legs done stay (with the log), the rest is the new way, and the timeline,
    /// alerts and Live Activity follow it. The journey keeps its id, which the sheet follows.
    @MainActor @Test func switchCarriesOnByTheNewWay() async throws {
        let planner = Planner([Self.dlr])
        let drive = await Self.early(with: planner)
        let trip = drive.trip!
        let before = trip.journey
        trip.acceptOffer()
        #expect(trip.offer == nil && drive.alerts.offered == nil)
        #expect(trip.journey.id == before.id)
        #expect(trip.journey.legs.prefix(2).map(\.id) == before.legs.prefix(2).map(\.id))
        #expect(trip.journey.legs.count == 6 && trip.journey.legs[4].line == "DLR")
        #expect(trip.log.boardings[1]?.departure?.scheduled == Self.at("06:26:00"))
        #expect(trip.legIndex == 1 && trip.boarded)
        #expect(trip.eta == Self.at("07:13:00"))
        #expect(drive.alerts.time("getoff.4") == Self.at("07:08:30"))
        #expect(trip.activityState().arrival == Self.at("07:13:00"))
        // The new way's rides get their boards, once.
        await Task.yield()
        #expect(drive.loaded.contains(trip.journey.legs[2].id))
        // Nothing to re-plan on the new way.
        drive.tick("06:30:00")
        #expect(planner.queries.count == 1)
    }

    /// Keep my route: the offer goes and that wait isn't asked about again, even at the next stop.
    @MainActor @Test func keepMyRouteSilencesTheReason() async {
        let planner = Planner([Self.dlr])
        let drive = await Self.early(with: planner)
        let trip = drive.trip!
        trip.keepRoute()
        #expect(trip.offer == nil && drive.alerts.offered == nil)
        drive.tick("06:34:10", at: T.bakerStreet)
        drive.tick("06:39:30")
        await trip.replanTask?.value
        #expect(planner.queries.count == 1)
        #expect(trip.offer == nil)
    }

    /// No signal underground: nothing is sent. Out at Baker Street (the next event), it asks.
    @MainActor @Test func noSignalSendsNothingUntilTheNextStop() async {
        let planner = Planner([Self.dlrWay(leaving: "06:37:00")])
        let journey = Self.toIsland
        let drive = T.Drive(journey, at: Self.at("06:22:00"), boards: Self.boards(journey), fix: T.paddington, search: planner.search)
        drive.online = false
        drive.tick("06:22:00", at: T.paddington)
        drive.clock = Self.at("06:26:20")
        drive.trip.take(.boarded(journey.legs[1]))
        #expect(drive.trip.replanTask == nil && planner.queries.isEmpty)
        drive.online = true
        drive.tick("06:34:10", at: T.bakerStreet)
        await drive.trip.replanTask?.value
        #expect(planner.queries.count == 1)
        // Now walking the change: asked from the Jubilee's platform, when the walk gets there.
        #expect(planner.queries.first?.origin.name == "Baker Street")
        #expect(planner.queries.first?.time == .departAt(Self.at("06:37:10")))
        #expect(drive.trip.offer != nil)
    }

    /// The planner had nothing better: no offer, and the wait's line says it was checked.
    @MainActor @Test func nothingBetterSaysTheWaitWasChecked() async {
        let slow = Self.candidate([(.tube, "Jubilee", "Baker Street", "Canary Wharf", "06:39:00", "06:59:00"),
                                   (.dlr, "DLR", "Heron Quays", "Crossharbour", "07:23:00", "07:28:00")],
                                  start: "06:34:00", end: "07:31:00")
        let planner = Planner([slow])
        let drive = await Self.early(with: planner)
        #expect(drive.trip.offer == nil && drive.alerts.offered == nil)
        #expect(drive.trip.replanStatus?.title == "You're early: 19 min wait for the 277")
        #expect(drive.trip.replanStatus?.detail == "At Canary Wharf Station, it leaves 07:20. Nothing quicker from there.")
    }

    /// "Find a faster way" on a trip going to plan: looks, and says the route is still the quickest.
    @MainActor @Test func findAFasterWayByHand() async throws {
        let planner = Planner([])
        let journey = T.bakerloo
        let drive = T.Drive(journey, at: Self.at("06:36:00"), boards: T.bakerlooBoards(journey), fix: T.paddington, search: planner.search)
        drive.tick("06:36:00", at: T.paddington)
        let trip = drive.trip!
        #expect(planner.queries.isEmpty)
        #expect(trip.canFindFaster)
        trip.findFaster()
        guard case .looking(let origin) = trip.replan else { Issue.record("not looking"); return }
        #expect(origin.name == "Paddington")
        await trip.replanTask?.value
        #expect(trip.replan == .said(Replan.Message(title: "Your route is still the quickest",
                                                    detail: "Nothing gets there sooner from Paddington than 07:20.",
                                                    short: "Still the quickest: arrive 07:20", compact: "Still the quickest")))
        // Inside the 4 minutes since, the button waits.
        #expect(!trip.canFindFaster)
    }

    /// A planner that never answers (a dead spot) can't make Go loop: two tries, then only a tap.
    @MainActor @Test func aDeadSpotCannotLoop() async {
        let planner = Planner([Self.dlr], answered: false)
        let drive = await Self.early(with: planner)
        let trip = drive.trip!
        #expect(planner.queries.count == 1)
        // Out at Baker Street, eight minutes on: one more try, which also gets nothing.
        drive.tick("06:34:10", at: T.bakerStreet)
        await trip.replanTask?.value
        #expect(planner.queries.count == 2)
        drive.tick("06:39:30")
        await trip.replanTask?.value
        drive.tick("06:45:00")
        drive.tick("06:59:30", at: T.canaryWharf)
        await trip.replanTask?.value
        drive.tick("07:01:30", at: Self.busStop)
        await trip.replanTask?.value
        #expect(planner.queries.count == 2)
        #expect(trip.replanWatch.failures == 2)
    }

    // MARK: The month's Google count

    @Test func searchesStepDownAsTheMonthFillsUp() {
        let now = Self.at("06:30:00")
        func requests(used: Int, deep: Bool = true) -> Int {
            var allowance = GoogleAllowance()
            allowance.spend(used, now: now)
            return allowance.searchRequests(deep: deep, variants: 5, now: now)
        }
        #expect(requests(used: 0) == 5)
        #expect(requests(used: 699) == 5)
        #expect(requests(used: 700) == 1)
        #expect(requests(used: 899) == 1)
        #expect(requests(used: 900) == 0)
        #expect(requests(used: 0, deep: false) == 1)
        #expect(requests(used: 950, deep: false) == 0)
        // A new month (Google's, in California) starts again.
        var allowance = GoogleAllowance()
        allowance.spend(950, now: now)
        #expect(allowance.searchRequests(deep: true, variants: 5, now: Time.iso("2026-12-01T09:00:00Z")!) == 5)
    }

    @MainActor @Test func theCountIsKeptOnThePhone() throws {
        let suite = "polaris.tests.google-usage"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let now = Self.at("06:30:00")
        GoogleUsage(defaults: defaults).spend(5, now: now)
        let again = GoogleUsage(defaults: defaults)
        again.spend(1, now: now)
        #expect(GoogleUsage(defaults: defaults).allowance.usedThisMonth(now: now) == 6)
        #expect(GoogleUsage(defaults: defaults).allowance.usedThisMonth(now: Time.iso("2026-12-01T09:00:00Z")!) == 0)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Review fixes

    /// From Paddington while waiting there: the Elizabeth line to Canary Wharf, 17 minutes sooner.
    static var elizabethWay: Journey {
        let legs = [
            Leg(mode: .elizabeth, line: "Elizabeth line", fromName: "Paddington", toName: "Canary Wharf",
                departure: at("06:40:00"), arrival: at("06:58:00"), path: [T.paddington, T.canaryWharf]),
            Leg(mode: .walk, fromName: "Canary Wharf", toName: "One Canada Square", departure: at("06:58:00"), arrival: at("07:03:00"),
                path: [T.canaryWharf, T.canadaSquare]),
        ]
        return Journey(departure: at("06:36:00"), arrival: at("07:03:00"), legs: legs, sources: [SourceTag(provider: .tfl, variant: "Fastest")])
    }

    /// Waiting at Paddington, "Find a faster way" offers the Elizabeth line from there.
    @MainActor static func offeredAtTheStop() async -> (T.Drive, Planner) {
        let planner = Planner([elizabethWay])
        let journey = T.bakerloo
        let drive = T.Drive(journey, at: at("06:36:00"), boards: T.bakerlooBoards(journey), fix: T.paddington, search: planner.search)
        drive.tick("06:36:00", at: T.paddington)
        drive.trip.findFaster()
        await drive.trip.replanTask?.value
        return (drive, planner)
    }

    /// An offer made at a stop replaces the ride there. Getting on that ride takes it back:
    /// Switch must never splice out the ride you're on.
    @MainActor @Test func boardingTheRideAtTheStopWithdrawsTheOffer() async throws {
        let (drive, _) = await Self.offeredAtTheStop()
        let trip = drive.trip!
        let offer = try #require(trip.offer)
        #expect(offer.origin.resumeAt == 1)
        drive.clock = Self.at("06:37:20")
        trip.take(.boarded(trip.journey.legs[1]))
        #expect(trip.offer == nil && drive.alerts.offered == nil)
        let before = trip.journey
        trip.acceptOffer()
        #expect(trip.journey == before)
        #expect(trip.journey.legs[1].line == "Bakerloo" && trip.boarded)
    }

    /// Switch tapped (from the notification, the app just woken) after the offer's first ride has
    /// gone: nothing changes, and Go says the offer has passed.
    @MainActor @Test func switchAfterTheOfferHasGoneDoesNothing() async throws {
        let (drive, _) = await Self.offeredAtTheStop()
        let trip = drive.trip!
        #expect(trip.offer != nil)
        let before = trip.journey
        drive.clock = Self.at("06:41:30")   // no tick: the app was suspended
        trip.acceptOffer()
        #expect(trip.journey == before)
        #expect(trip.offer == nil && drive.alerts.offered == nil)
        guard case .said(let message) = trip.replan else { Issue.record("said nothing"); return }
        #expect(message.title == "That faster way has gone")
    }

    /// On the tick, an offer whose first ride has gone is taken back, notification included.
    @MainActor @Test func aStaleOfferIsWithdrawnOnTheTick() async {
        let (drive, _) = await Self.offeredAtTheStop()
        #expect(drive.trip.offer != nil)
        drive.tick("06:40:20", at: T.paddington)
        #expect(drive.trip.offer != nil)
        drive.tick("06:40:40", at: T.paddington)
        #expect(drive.trip.offer == nil && drive.alerts.offered == nil)
    }

    /// Three searches a trip, answered or not, taps included.
    @Test func threeSendsATripWhateverHappens() {
        var watch = Replan.Watch()
        let t0 = Self.at("06:30:00")
        watch.asked(.missed(leg: 1, late: 600), now: t0, usedGoogle: false, answered: false)
        watch.asked(.lostConnection(leg: 3, late: 600), now: t0.addingTimeInterval(300), usedGoogle: false, answered: false)
        // Two automatic tries got nothing: only a tap now, and it's the trip's third and last.
        #expect(!watch.mayAsk(.cancelled(leg: 5), now: t0.addingTimeInterval(600)))
        #expect(watch.mayAsk(.asked, now: t0.addingTimeInterval(600)))
        watch.asked(.asked, now: t0.addingTimeInterval(600), usedGoogle: false, answered: false)
        #expect(!watch.mayAsk(.asked, now: t0.addingTimeInterval(1200)))
        #expect(watch.sends == 3)
    }

    /// After a Switch the legs are new: what was settled about the old ones from the stop on is forgotten.
    @MainActor @Test func aSwitchForgetsReasonsAboutTheOldLegs() async {
        let planner = Planner([Self.dlr])
        let drive = await Self.early(with: planner)
        #expect(drive.trip.replanWatch.settled.contains("wait.5"))
        drive.trip.acceptOffer()
        #expect(!drive.trip.replanWatch.settled.contains("wait.5"))
    }

    /// When TfL's status couldn't be had, the offer still goes, and says it wasn't checked.
    @MainActor @Test func anOfferWithoutTfLStatusSaysSo() async throws {
        let planner = Planner([Self.dlr])
        planner.answer.statusChecked = false
        let drive = await Self.early(with: planner)
        let words = try #require(drive.trip.offerMessage)
        #expect(words.detail.hasSuffix(" TfL's line status couldn't be checked."))
        #expect(drive.alerts.offered?.detail == words.detail)
    }

    /// Google in a search, as the month fills up: the plan `SearchModel` follows and spends.
    @Test func searchesPlanTheirGoogleRequests() {
        let now = Self.at("06:30:00")
        var allowance = GoogleAllowance()
        #expect(SearchModel.googlePlan(enabled: true, hasKey: true, deep: true, allowance: allowance, now: now) == .ask(5))
        #expect(SearchModel.googlePlan(enabled: true, hasKey: true, deep: false, allowance: allowance, now: now) == .ask(1))
        #expect(SearchModel.googlePlan(enabled: false, hasKey: true, deep: true, allowance: allowance, now: now) == .off("Turned off"))
        #expect(SearchModel.googlePlan(enabled: true, hasKey: false, deep: true, allowance: allowance, now: now) == .off("Add a key in Settings"))
        allowance.spend(750, now: now)
        #expect(SearchModel.googlePlan(enabled: true, hasKey: true, deep: true, allowance: allowance, now: now) == .ask(1))
        allowance.spend(150, now: now)
        #expect(SearchModel.googlePlan(enabled: true, hasKey: true, deep: true, allowance: allowance, now: now) == .off("Free allowance used this month"))
    }
}
