import Foundation
import Testing
@testable import Polaris

/// Following a journey: where you are on a walk, what to do next, whether you'll
/// make the train, and which leg you're on.
struct LiveTripTests {
    static let t0 = Time.iso("2026-10-31T10:00:00Z")!
    // A, B and C about 280 m apart along a parallel; D south of C.
    static let a = Coordinate(latitude: 51.5300, longitude: -0.1300)
    static let b = Coordinate(latitude: 51.5300, longitude: -0.1260)
    static let c = Coordinate(latitude: 51.5300, longitude: -0.1000)
    static let d = Coordinate(latitude: 51.5280, longitude: -0.1000)

    static var journey: Journey { journey(startingAt: t0) }

    /// Walk A→B for 5 min, Northern B→C for 10, walk C→D for 5.
    static func journey(startingAt t0: Date) -> Journey {
        let walk = Leg(mode: .walk, fromName: "Start", toName: "B", departure: t0, arrival: t0.addingTimeInterval(300),
                       distanceMeters: 280, path: [a, b])
        let ride = Leg(mode: .tube, line: "Northern", headsign: "Morden", fromName: "B", toName: "C",
                       departure: t0.addingTimeInterval(300), arrival: t0.addingTimeInterval(900), stopCount: 3,
                       path: [b, c], platform: "8")
        let last = Leg(mode: .walk, fromName: "C", toName: "D", departure: t0.addingTimeInterval(900),
                       arrival: t0.addingTimeInterval(1200), path: [c, d])
        return Journey(departure: t0, arrival: t0.addingTimeInterval(1200), legs: [walk, ride, last],
                       sources: [SourceTag(provider: .tfl, variant: "Fastest")])
    }

    @Test func locatesYouAlongAPath() throws {
        let length = PathProgress.length(of: [Self.a, Self.b])
        #expect(abs(length - 277) < 5)
        // Halfway along, 30 m north of the line.
        let point = Coordinate(latitude: 51.53027, longitude: -0.1280)
        let progress = try #require(PathProgress.locate(point, on: [Self.a, Self.b]))
        #expect(abs(progress.distanceFromPath - 30) < 3)
        #expect(abs(progress.distanceAlong - length / 2) < 5)
        #expect(abs(progress.remaining - length / 2) < 5)
        // Past the end clamps to it.
        let beyond = try #require(PathProgress.locate(Coordinate(latitude: 51.53, longitude: -0.1200), on: [Self.a, Self.b]))
        #expect(beyond.remaining == 0)
    }

    @Test func guidanceNamesTheNextTurnAndHowFar() {
        let route = WalkRoute(path: [Self.a, Self.b], steps: [
            .init(instruction: "", distance: 40),
            .init(instruction: "Turn right onto Argyle Street", distance: 100),
            .init(instruction: "Turn left onto Euston Road", distance: 60),
        ], distance: 200, expectedTime: 150)
        let start = route.guidance(at: 10)
        #expect(start.instruction == "Turn right onto Argyle Street")
        #expect(start.distance == 30)
        let middle = route.guidance(at: 100)
        #expect(middle.instruction == "Turn left onto Euston Road")
        #expect(middle.distance == 40)
        let end = route.guidance(at: 150)
        #expect(end.instruction == nil)
        #expect(end.distance == 50)
    }

    @Test func connectionVerdicts() {
        let now = Self.t0
        // 270 m at 1.35 m/s is 200 s, plus 90 s to the platform.
        let tight = Connection.make(remaining: 270, speed: nil, now: now, departure: now.addingTimeInterval(400), mode: .tube)
        #expect(tight.ready == now.addingTimeInterval(290))
        #expect(tight.verdict == .tight)
        #expect(Connection.make(remaining: 270, speed: nil, now: now, departure: now.addingTimeInterval(600), mode: .tube).verdict == .comfortable)
        #expect(Connection.make(remaining: 270, speed: nil, now: now, departure: now.addingTimeInterval(200), mode: .tube).verdict == .missing)
        // A brisk measured pace makes it.
        #expect(Connection.make(remaining: 270, speed: 2.2, now: now, departure: now.addingTimeInterval(250), mode: .tube).verdict == .tight)
        // Buses need less time from the pavement.
        #expect(Connection.platformTime(.bus) < Connection.platformTime(.tube))
    }

    @Test func movesOnLegByLeg() {
        let journey = Self.journey
        #expect(TripProgress.initialLeg(journey, now: Self.t0) == 0)
        // Started late, mid-ride.
        #expect(TripProgress.initialLeg(journey, now: Self.t0.addingTimeInterval(600)) == 1)
        // Still walking: stays put.
        #expect(TripProgress.advance(journey, from: 0, now: Self.t0.addingTimeInterval(60), location: Self.a) == 0)
        // At the station: on to the ride.
        #expect(TripProgress.advance(journey, from: 0, now: Self.t0.addingTimeInterval(200), location: Self.b) == 1)
        // Underground with no fix: time moves the ride on.
        #expect(TripProgress.advance(journey, from: 1, now: Self.t0.addingTimeInterval(880), location: nil) == 2)
        #expect(TripProgress.advance(journey, from: 1, now: Self.t0.addingTimeInterval(600), location: nil) == 1)
        // Still on the platform after it's due in: you didn't get on.
        #expect(TripProgress.advance(journey, from: 1, now: Self.t0.addingTimeInterval(960), location: Self.b) == 1)
        #expect(TripProgress.missed(journey.legs[1], now: Self.t0.addingTimeInterval(420), location: Self.b))
        #expect(!TripProgress.missed(journey.legs[1], now: Self.t0.addingTimeInterval(420), location: Self.c))
    }

    @MainActor @Test func liveActivityStateIsSmallAndSaysWhatToDo() throws {
        let query = JourneyQuery(origin: Place(name: "Start", coordinate: Self.a), destination: Place(name: "D", coordinate: Self.d), time: .leaveNow)
        let trip = LiveTrip(journey: Self.journey(startingAt: .now.addingTimeInterval(60)), query: query,
                            location: LocationService(), departures: DepartureStore(), alerts: RecordedAlerts())
        let state = trip.activityState()
        #expect(state.title == "Walk to B")
        #expect(state.lineName == "Northern")
        #expect(state.countdownLabel == "Leaves")
        #expect(state.lineColor == nil)
        let size = try JSONEncoder().encode(state).count + JSONEncoder().encode(TripActivityAttributes(destination: "D")).count
        #expect(size < 4096)
    }

    // MARK: If you miss it

    /// The recorded Northern from King's Cross (18:08, at Bank 18:17; the next is
    /// 18:11, at Bank 18:20), a 5 min walk, then a train at `trainLeaves` for 26 min,
    /// then a 5 min walk to the end.
    static func connecting(trainLeaves: String) -> Journey {
        let northern = DepartureTests.northernLeg()
        let bank = Leg(mode: .walk, fromName: "Bank", toName: "Liverpool Street", departure: northern.arrival,
                       arrival: northern.arrival.addingTimeInterval(300))
        let leaves = Time.iso(trainLeaves)!
        let train = Leg(mode: .rail, line: "Greater Anglia", headsign: "Southend Victoria", fromName: "Liverpool Street", toName: "Southend Victoria",
                        departure: leaves, arrival: leaves.addingTimeInterval(26 * 60))
        let last = Leg(mode: .walk, fromName: "Southend Victoria", toName: "Southend Pier", departure: train.arrival,
                       arrival: train.arrival.addingTimeInterval(300))
        return Journey(departure: northern.departure, arrival: last.arrival, legs: [northern, bank, train, last],
                       sources: [SourceTag(provider: .tfl, variant: "Fastest")])
    }

    /// Greater Anglia trains every quarter of an hour from the planned one; empty to have none.
    static func trainBoard(_ train: Leg, every: [Int] = [0, 15, 30]) -> DepartureBoard {
        let departures = every.map { minutes in
            let leaves = train.departure.addingTimeInterval(TimeInterval(minutes * 60))
            return Departure(id: "ga-\(minutes)", line: "Greater Anglia", mode: .rail, headsign: "Southend Victoria", stopName: "Liverpool Street",
                             stopCoordinate: DepartureTests.bank, scheduled: leaves, expected: leaves, isRealtime: false,
                             isCancelled: false, arrivalThere: leaves.addingTimeInterval(train.duration))
        }
        return DepartureBoard(stopName: "Liverpool Street", departures: departures, plannedID: departures.isEmpty ? nil : "ga-0")
    }

    static func ifMissed(_ journey: Journey, train: DepartureBoard?) throws -> IfMissed? {
        let northern = try DepartureTests.board(journey.legs[0])
        return IfMissed.make(journey, ride: 0) { $0.mode == .tube ? northern : $0.mode == .rail ? train : nil }
    }

    @Test func missingItCanCostTheTrainAfter() throws {
        // At Liverpool Street 18:22 for the 18:24: the 18:11 Northern gets you there at 18:25, too late for it.
        let journey = Self.connecting(trainLeaves: "2026-10-31T18:24:00Z")
        let missed = try #require(try Self.ifMissed(journey, train: Self.trainBoard(journey.legs[2])))
        #expect(missed.next.scheduled == Time.iso("2026-10-31T18:11:00Z"))
        #expect(missed.losesConnection)
        #expect(missed.connection?.line == "Greater Anglia")
        // The 18:39 instead: there 15 min later, not 3.
        #expect(missed.cost == 15)
        #expect(!missed.costIsFloor)
    }

    @Test func missingItCanCostNothing() throws {
        // The train isn't until 18:35: the 18:11 still makes it, so you arrive at the same time.
        let journey = Self.connecting(trainLeaves: "2026-10-31T18:35:00Z")
        let missed = try #require(try Self.ifMissed(journey, train: Self.trainBoard(journey.legs[2])))
        #expect(!missed.losesConnection)
        #expect(missed.connection?.line == "Greater Anglia")
        #expect(missed.cost == 0)
    }

    @Test func missingItWithLittleToGoOn() throws {
        let journey = Self.connecting(trainLeaves: "2026-10-31T18:24:00Z")
        // No board for the train: you'd miss it, but how late you'd be is unknown.
        let unknown = try #require(try Self.ifMissed(journey, train: nil))
        #expect(unknown.losesConnection)
        #expect(unknown.cost == nil)
        // A board with nothing after yours: at least as late as the board reaches (30 min after it).
        let floor = try #require(try Self.ifMissed(journey, train: Self.trainBoard(journey.legs[2], every: [0])))
        #expect(floor.costIsFloor)
        #expect(floor.cost == 30)
    }

    /// The Lock Screen puts the cost under the countdown and the reason underneath.
    @MainActor @Test func liveActivitySaysWhatMissingItCosts() throws {
        let journey = Self.connecting(trainLeaves: "2026-10-31T18:24:00Z")
        let missed = try Self.ifMissed(journey, train: Self.trainBoard(journey.legs[2]))
        var state = TripActivityAttributes.ContentState(symbol: "tram.fill", title: "", detail: "", countdownLabel: "Leaves",
                                                        countdownTo: journey.departure, arrival: journey.arrival, step: 1, stepCount: 4)
        #expect(state.missDetail == nil && state.missCostText == nil)

        LiveTrip.addMissIt(missed, ride: journey.legs[0], to: &state)
        let clock = TripActivityAttributes.ContentState.clock
        #expect(state.nextLine == nil)
        #expect(state.missCostText == "+15 min")
        #expect(state.missIsCostly)
        #expect(state.missDetail == "Next \(clock(state.nextDeparture!)), misses the \(clock(journey.legs[2].departure)) Greater Anglia")

        // Still makes it.
        state.missCost = 0
        state.losesConnection = false
        #expect(state.missCostText == "no later")
        #expect(!state.missIsCostly)
        #expect(state.missDetail == "Next \(clock(state.nextDeparture!)), still makes the \(clock(journey.legs[2].departure)) Greater Anglia")
        // Past what the boards know.
        state.missCost = 30
        state.missCostIsFloor = true
        #expect(state.missCostText == "30+ min")
        let size = try JSONEncoder().encode(state).count + JSONEncoder().encode(TripActivityAttributes(destination: "Southend Victoria")).count
        #expect(size < 4096)
    }

    // MARK: Already aboard

    /// Walk A→B, the 25 bus B→C (about 1.8 km east), walk C→D.
    static func busJourney(startingAt t0: Date) -> Journey {
        var journey = journey(startingAt: t0)
        journey.legs[1].mode = .bus
        journey.legs[1].line = "25"
        journey.legs[1].platform = nil
        return journey
    }

    /// `metres` east of B, on the bus's road.
    static func alongRide(_ metres: Double) -> Coordinate {
        Coordinate(latitude: b.latitude, longitude: b.longitude + metres / (111_320 * cos(b.latitude * .pi / 180)))
    }

    @Test func noticesYoureAlreadyOnTheBus() {
        let journey = Self.busJourney(startingAt: Self.t0)
        var detector = BoardingDetector()
        // On an earlier bus: moving along its road at 6 m/s, past where you'd get on.
        var found: [Int?] = []
        for second in stride(from: 0.0, through: 14, by: 2) {
            found.append(detector.ride(journey, from: 0, location: Self.alongRide(150 + second * 6), now: Self.t0.addingTimeInterval(second)))
        }
        #expect(found.prefix(3).allSatisfy { $0 == nil }, "not from one fix")
        #expect(found.last == 1)
    }

    @Test func walkingAlongTheBusRouteIsntRiding() {
        let journey = Self.busJourney(startingAt: Self.t0)
        var walking = BoardingDetector()
        var towards = BoardingDetector()
        var waiting = BoardingDetector()
        for second in stride(from: 0.0, through: 60, by: 2) {
            let at = Self.t0.addingTimeInterval(second)
            // Briskly, the way the bus goes.
            #expect(walking.ride(journey, from: 0, location: Self.alongRide(150 + second * 1.6), now: at) == nil)
            // Towards the stop from the far side, the way people come to it.
            #expect(towards.ride(journey, from: 0, location: Self.alongRide(400 - second * 1.4), now: at) == nil)
            // At the stop.
            #expect(waiting.ride(journey, from: 1, location: Self.alongRide(10), now: at) == nil)
        }
    }

    @Test func getsOffWhereYouAreNotWhenThePlanSaid() {
        let journey = Self.busJourney(startingAt: Self.t0)
        // An earlier bus: at C two minutes before the planned one gets in.
        #expect(TripProgress.advance(journey, from: 1, now: Self.t0.addingTimeInterval(780), location: Self.c) == 2)
        // A later bus: the plan's time has come, but your bus isn't due yet.
        let late = Self.t0.addingTimeInterval(1100)
        #expect(TripProgress.advance(journey, from: 1, now: Self.t0.addingTimeInterval(900), location: Self.alongRide(900), rideArrival: late) == 1)
        #expect(TripProgress.advance(journey, from: 1, now: late, location: nil, rideArrival: late) == 2)
    }

    @MainActor @Test func oneTapSaysYoureOnItThenOff() {
        let query = JourneyQuery(origin: Place(name: "Start", coordinate: Self.a), destination: Place(name: "D", coordinate: Self.d), time: .leaveNow)
        let journey = Self.busJourney(startingAt: .now.addingTimeInterval(60))
        let trip = LiveTrip(journey: journey, query: query, location: LocationService(), departures: DepartureStore(),
                            routeWalk: { _, _ in nil }, alerts: RecordedAlerts())
        #expect(trip.legIndex == 0)
        #expect(trip.manualStep == .boarded(journey.legs[1]))
        #expect(trip.busWatch?.lineID == "25")
        trip.take(.boarded(journey.legs[1]))
        // On it before it was due to leave: the step says when to get off, not a countdown.
        #expect(trip.legIndex == 1)
        #expect(!trip.isWaiting)
        #expect(trip.manualStep == .gotOff(journey.legs[1]))
        #expect(trip.activityState().countdownLabel == "Get off")
        trip.take(.gotOff(journey.legs[1]))
        #expect(trip.legIndex == 2)
        #expect(trip.manualStep == nil)
    }

    // MARK: Keeping time with what you do

    /// Paddington, then Baker Street on the Bakerloo and the Jubilee's Baker Street platform.
    /// Norfolk Square, a public garden by Paddington; One Canada Square, the tower at Canary Wharf.
    static let start = Coordinate(latitude: 51.5154, longitude: -0.1739)
    static let paddington = Coordinate(latitude: 51.5182, longitude: -0.1757)
    static let bakerStreet = Coordinate(latitude: 51.5226, longitude: -0.1571)
    static let jubileePlatform = Coordinate(latitude: 51.5230, longitude: -0.1570)
    static let canaryWharf = Coordinate(latitude: 51.5035, longitude: -0.0187)
    static let canadaSquare = Coordinate(latitude: 51.5049, longitude: -0.0195)

    static func at(_ clock: String) -> Date { Time.iso("2026-11-16T\(clock)Z")! }

    /// The sample trip, as planned: walk 06:34–06:39 to Paddington, the 06:41 Bakerloo to
    /// Baker Street (06:49), three minutes to the Jubilee, the 06:55 to Canary Wharf
    /// (07:15), and a five-minute walk: there at 07:20.
    static var bakerloo: Journey {
        let walk = Leg(mode: .walk, fromName: "Norfolk Square", toName: "Paddington", departure: at("06:34:00"), arrival: at("06:39:00"),
                       distanceMeters: 300, path: [start, paddington])
        let bakerloo = Leg(mode: .tube, line: "Bakerloo", headsign: "Elephant & Castle", fromName: "Paddington", toName: "Baker Street",
                           departure: at("06:41:00"), arrival: at("06:49:00"), stopCount: 3, path: [paddington, bakerStreet], platform: "3")
        let change = Leg(mode: .walk, fromName: "Baker Street", toName: "Baker Street", departure: at("06:49:00"), arrival: at("06:52:00"),
                         path: [bakerStreet, jubileePlatform])
        let jubilee = Leg(mode: .tube, line: "Jubilee", headsign: "Stratford", fromName: "Baker Street", toName: "Canary Wharf",
                          departure: at("06:55:00"), arrival: at("07:15:00"), stopCount: 9, path: [jubileePlatform, canaryWharf])
        let last = Leg(mode: .walk, fromName: "Canary Wharf", toName: "One Canada Square", departure: at("07:15:00"), arrival: at("07:20:00"),
                       path: [canaryWharf, canadaSquare])
        return Journey(departure: at("06:34:00"), arrival: at("07:20:00"), legs: [walk, bakerloo, change, jubilee, last],
                       sources: [SourceTag(provider: .tfl, variant: "Fastest")])
    }

    /// A line's board: one train at each time, `run` minutes to where you get off,
    /// the planned one leaving at `planned`.
    static func tubeBoard(_ leg: Leg, at times: [String], run: Double, planned: String) -> DepartureBoard {
        let departures = times.map { time in
            Departure(id: "\(leg.line!)-\(time)", line: leg.line!, mode: .tube, headsign: leg.headsign ?? "", stopName: leg.fromName,
                      stopCoordinate: leg.start!, scheduled: at(time), expected: at(time), isRealtime: true, isCancelled: false,
                      arrivalThere: at(time).addingTimeInterval(run * 60))
        }
        return DepartureBoard(stopName: leg.fromName, departures: departures, plannedID: "\(leg.line!)-\(planned)")
    }

    static func bakerlooBoards(_ journey: Journey) -> [UUID: DepartureBoard] {
        [journey.legs[1].id: tubeBoard(journey.legs[1], at: ["06:22:00", "06:26:00", "06:30:00", "06:34:00", "06:37:00", "06:41:00",
                                                             "06:44:00", "06:48:00", "06:52:00", "06:56:00", "07:00:00", "07:04:00"],
                                       run: 8, planned: "06:41:00"),
         journey.legs[3].id: tubeBoard(journey.legs[3], at: ["06:35:00", "06:39:00", "06:43:00", "06:47:00", "06:51:00", "06:55:00",
                                                             "06:59:00", "07:03:00", "07:07:00", "07:11:00", "07:15:00"],
                                       run: 20, planned: "06:55:00")]
    }

    /// Pending alerts as Go hands them over, kept in a list instead of the notification centre.
    @MainActor final class RecordedAlerts: TripAlertScheduling {
        var pending: [TripAlert] = []
        var schedules = 0
        /// The faster way on show as a notification, if any.
        var offered: Replan.Message?
        func schedule(_ alerts: [TripAlert]) { pending = alerts; schedules += 1 }
        func cancel() { pending = [] }
        func offer(_ message: Replan.Message?) { offered = message }
        func time(_ id: String) -> Date? { pending.first { $0.id == id }?.date }
    }

    /// A trip driven by hand: its clock, its fix and its boards are the test's.
    @MainActor final class Drive {
        var clock: Date
        var fix: LiveTrip.Fix?
        var boards: [UUID: DepartureBoard]
        let alerts = RecordedAlerts()
        var loaded: [UUID] = []
        /// Whether the phone has a way to the internet, for re-plans.
        var online = true
        var trip: LiveTrip!

        init(_ journey: Journey, at start: Date, boards: [UUID: DepartureBoard], fix: Coordinate?,
             search: ReplanSearch.Search? = nil) {
            clock = start
            self.boards = boards
            self.fix = fix.map { LiveTrip.Fix(coordinate: $0, at: start) }
            let query = JourneyQuery(origin: Place(name: "Norfolk Square", coordinate: journey.legs[0].start!),
                                     destination: Place(name: "One Canada Square", coordinate: journey.legs.last!.end!), time: .leaveNow)
            trip = LiveTrip(journey: journey, query: query, location: LocationService(), departures: DepartureStore(),
                            clock: { [weak self] in self?.clock ?? start }, fix: { [weak self] in self?.fix },
                            boards: { [weak self] in self?.boards[$0.id] }, loadBoard: { [weak self] in self?.loaded.append($0.id) },
                            routeWalk: { _, _ in nil }, alerts: alerts,
                            search: search, isOnline: { [weak self] in self?.online ?? false })
        }

        /// The clock moves on to `time`; a fix there if given (else the last one, ageing).
        func tick(_ time: String, at place: Coordinate? = nil) {
            clock = LiveTripTests.at(time)
            if let place { fix = LiveTrip.Fix(coordinate: place, at: clock) }
            trip.refresh()
        }
    }

    @MainActor @Test func aLoopNeedsDepartureAndTwoGoodArrivalFixes() {
        let start = Self.at("06:25:00"), end = start.addingTimeInterval(600)
        let leg = Leg(mode: .walk, fromName: "A", toName: "A", departure: start, arrival: end,
                      path: [Self.a, Self.b, Self.a])
        let journey = Journey(departure: start, arrival: end, legs: [leg], sources: [])
        let drive = Drive(journey, at: start, boards: [:], fix: Self.a)
        drive.tick("06:25:00", at: Self.a)
        drive.tick("06:25:04", at: Self.a)
        #expect(drive.trip.completion == nil)

        drive.tick("06:27:00", at: Self.b)
        drive.clock = Self.at("06:32:00")
        drive.fix = LiveTrip.Fix(coordinate: Self.a, at: start)
        drive.trip.refresh()
        drive.fix = LiveTrip.Fix(coordinate: Self.a, at: drive.clock, horizontalAccuracy: 85)
        drive.trip.refresh()
        drive.tick("06:32:05", at: Self.a)
        drive.tick("06:32:08")  // The same fix again.
        #expect(drive.trip.completion == nil)
        drive.tick("06:32:10", at: Self.a)
        #expect(drive.trip.completion == .arrived)
    }

    /// The sample Bakerloo trip: at Paddington ten minutes early, on the 06:30 instead of the
    /// 06:41 with a tap, no fix underground (the phone keeps Paddington's), then out at
    /// Baker Street. Every time downstream follows: the train, the get-off time, the
    /// Jubilee now made, the arrival and the pending alerts.
    @MainActor @Test func keepsTimeWithAnEarlierTrain() throws {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:25:00"), boards: Self.bakerlooBoards(journey), fix: Self.start)
        let trip = drive.trip!
        drive.tick("06:25:00")
        // As planned before setting off.
        #expect(trip.legIndex == 0)
        #expect(trip.eta == Self.at("07:20:00"))
        #expect(drive.alerts.time("leave") == Self.at("06:33:00"))
        #expect(drive.alerts.time("getoff.1") == Self.at("06:47:30"))
        #expect(drive.alerts.time("getoff.3") == Self.at("07:13:30"))

        // At Paddington by 06:28, then down to the platform: the fix stays there.
        drive.tick("06:28:00", at: Self.paddington)
        #expect(trip.legIndex == 1)
        #expect(trip.isWaiting)
        #expect(trip.rideDeparture == Self.at("06:41:00"))
        #expect(trip.manualStep == .boarded(journey.legs[1]))

        // On the 06:30, says the tap at 06:30:20.
        drive.clock = Self.at("06:30:20")
        trip.take(.boarded(journey.legs[1]))
        #expect(trip.boarded)
        #expect(trip.yourDeparture?.scheduled == Self.at("06:30:00"))
        #expect(trip.rideDeparture == Self.at("06:30:00"))
        #expect(trip.rideArrival == Self.at("06:38:00"))
        #expect(trip.timeline.journey.legs[1].departure == Self.at("06:30:00"))
        // Out at 06:38, the change by 06:41: the 06:43 Jubilee, not the 06:55, so 07:08, not 07:20.
        #expect(trip.timeline.steps[3].service?.scheduled == Self.at("06:43:00"))
        #expect(trip.eta == Self.at("07:08:00"))
        let state = trip.activityState()
        #expect(state.countdownLabel == "Get off")
        #expect(state.countdownTo == Self.at("06:38:00"))
        #expect(state.arrival == Self.at("07:08:00"))
        #expect(state.detail.contains("06:30"))
        #expect(drive.alerts.time("leave") == nil)
        #expect(drive.alerts.time("getoff.1") == Self.at("06:36:30"))
        #expect(drive.alerts.time("getoff.3") == Self.at("07:01:30"))
        #expect(drive.alerts.pending.first { $0.id == "getoff.1" }?.body == "Then the Jubilee at 06:43 from Baker Street.")

        // A stop away, the phone still holding Paddington's fix: get off in about 3 min, not 11,
        // and the ride isn't held at Paddington by that old fix.
        drive.tick("06:35:00")
        #expect(trip.legIndex == 1)
        #expect(Int(trip.rideArrival.timeIntervalSince(trip.now) / 60) == 3)
        #expect(!trip.missedRide)
        let estimate = try #require(trip.estimatedPosition)
        #expect(estimate.distance(to: Self.paddington) > 500 && estimate.distance(to: Self.bakerStreet) > 300)

        // Out at Baker Street at 06:38:10, a fix there: the ride is done and its alert goes.
        drive.tick("06:38:10", at: Self.bakerStreet)
        #expect(trip.legIndex == 2)
        #expect(trip.log.ended[1] == Self.at("06:38:10"))
        #expect(drive.alerts.time("getoff.1") == nil)
        #expect(trip.nextRideDeparture == Self.at("06:43:00"))
        #expect(trip.eta == Self.at("07:08:00"))
        #expect(drive.alerts.time("getoff.3") == Self.at("07:01:30"))
        #expect(trip.activityState().countdownTo == Self.at("06:43:00"))
    }

    /// Off later than the train you're on said (held outside the station): the change and
    /// everything after move to the next Jubilee you can make.
    @MainActor @Test func gettingOffLateMovesTheRestOn() {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:28:00"), boards: Self.bakerlooBoards(journey), fix: Self.paddington)
        let trip = drive.trip!
        drive.tick("06:28:00", at: Self.paddington)
        drive.clock = Self.at("06:30:20")
        trip.take(.boarded(journey.legs[1]))
        #expect(trip.eta == Self.at("07:08:00"))
        // Held: off at 06:40:30 instead of 06:38, at the change by 06:43:30, so the 06:47.
        drive.clock = Self.at("06:40:30")
        trip.take(.gotOff(journey.legs[1]))
        #expect(trip.timeline.steps[3].service?.scheduled == Self.at("06:47:00"))
        #expect(trip.eta == Self.at("07:12:00"))
        #expect(drive.alerts.time("getoff.3") == Self.at("07:05:30"))
        // Back to the ride by hand: what happened from there is forgotten.
        trip.select(1)
        #expect(trip.log.ended[1] == nil && !trip.boarded)
        // Ending Go clears every alert.
        trip.stop()
        #expect(drive.alerts.pending.isEmpty)
    }

    /// Still on the platform after the planned one left (a fresh fix says so): the trip
    /// moves to the next one you could have caught since you were last seen there.
    @MainActor @Test func missingThePlannedTrainMovesToTheNext() {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:38:00"), boards: Self.bakerlooBoards(journey), fix: Self.paddington)
        let trip = drive.trip!
        drive.tick("06:38:00", at: Self.paddington)
        #expect(trip.rideDeparture == Self.at("06:41:00"))
        drive.tick("06:42:30", at: Self.paddington)
        #expect(trip.missedRide)
        #expect(trip.rideDeparture == Self.at("06:44:00"))
        #expect(trip.isWaiting)
        #expect(trip.rideArrival == Self.at("06:52:00"))
        // Jubilee from 06:56: the 06:59, there 07:19, at the tower 07:24.
        #expect(trip.eta == Self.at("07:24:00"))
        #expect(drive.alerts.time("getoff.1") == Self.at("06:50:30"))
    }

    /// The recorded Northern board: a tap three minutes before the planned 18:08 puts you
    /// on the 18:05 to Morden, and its own time at Bank is when you get off.
    @MainActor @Test func boardingSnapsToTheRecordedBoard() throws {
        let northern = DepartureTests.northernLeg()
        let board = try DepartureTests.board(northern)
        let walk = Leg(mode: .walk, fromName: "Bank", toName: "One Canada Square", departure: northern.arrival,
                       arrival: northern.arrival.addingTimeInterval(300), path: [DepartureTests.bank, Self.canadaSquare])
        let journey = Journey(departure: northern.departure, arrival: walk.arrival, legs: [northern, walk],
                              sources: [SourceTag(provider: .tfl, variant: "Fastest")])
        let drive = Drive(journey, at: Time.iso("2026-10-31T18:04:00Z")!, boards: [northern.id: board], fix: nil)
        let trip = drive.trip!
        #expect(trip.isWaiting)
        drive.clock = Time.iso("2026-10-31T18:05:20Z")!
        trip.take(.boarded(northern))
        let yours = try #require(trip.yourDeparture)
        #expect(yours.scheduled == Time.iso("2026-10-31T18:05:00Z"))
        #expect(yours.headsign == "Morden")
        let there = try #require(yours.arrivalThere)
        #expect(trip.rideArrival == there)
        #expect(there < Time.iso("2026-10-31T18:17:00Z")!)
        #expect(trip.eta == there.addingTimeInterval(300))
    }

    @Test func snapsToTheTrainNearestTheTap() {
        let leg = Self.bakerloo.legs[1]
        let board = Self.tubeBoard(leg, at: ["06:30:00", "06:34:00"], run: 8, planned: "06:34:00")
        // Just after one left, it's that one.
        #expect(TripLog.departure(boardedAt: Self.at("06:31:30"), on: board)?.scheduled == Self.at("06:30:00"))
        // Just before one leaves, that one.
        #expect(TripLog.departure(boardedAt: Self.at("06:33:40"), on: board)?.scheduled == Self.at("06:34:00"))
        // Nothing near: the moment itself stands in.
        #expect(TripLog.departure(boardedAt: Self.at("06:50:00"), on: board) == nil)
        #expect(TripLog.departure(boardedAt: Self.at("06:31:00"), on: nil) == nil)
    }

    /// No boards at all: the tap's moment and the ride's run time.
    @MainActor @Test func boardingWithNoBoardTimesFromTheTap() {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:28:00"), boards: [:], fix: Self.paddington)
        let trip = drive.trip!
        drive.tick("06:28:00", at: Self.paddington)
        drive.clock = Self.at("06:31:00")
        trip.take(.boarded(journey.legs[1]))
        #expect(trip.rideArrival == Self.at("06:39:00"))
        // Early for the Jubilee with no board to say what's sooner: the planned one, 07:20.
        #expect(trip.eta == Self.at("07:20:00"))
    }

    /// Alerts stay pending right up to when they're due: Go re-plans every two seconds,
    /// and an alert dropped from the plan just before its time would never fire.
    @MainActor @Test func alertsSurviveUntilTheyFire() {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:25:00"), boards: Self.bakerlooBoards(journey), fix: Self.start)
        drive.tick("06:25:00")
        #expect(drive.alerts.time("leave") == Self.at("06:33:00"))
        // Still at the start two minutes before it: leave stays.
        drive.tick("06:31:30")
        drive.tick("06:32:45")
        #expect(drive.alerts.time("leave") == Self.at("06:33:00"))
        // At Paddington, on the 06:41 as planned: get off at 06:47:30.
        drive.tick("06:39:00", at: Self.paddington)
        drive.clock = Self.at("06:41:10")
        drive.trip.take(.boarded(journey.legs[1]))
        #expect(drive.alerts.time("getoff.1") == Self.at("06:47:30"))
        drive.tick("06:47:10")
        #expect(drive.alerts.time("getoff.1") == Self.at("06:47:30"))
        // Once its time has gone, it's gone from the plan.
        drive.tick("06:47:40")
        #expect(drive.alerts.time("getoff.1") == nil)
    }

    /// No fix on a change between lines (deep underground): the walk keeps its planned
    /// time instead of stretching with the clock, so the onward train and its alert hold.
    @MainActor @Test func aChangeWithNoFixHoldsTheOnwardTrain() {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:39:00"), boards: Self.bakerlooBoards(journey), fix: Self.paddington)
        drive.tick("06:39:00", at: Self.paddington)
        drive.clock = Self.at("06:41:10")
        drive.trip.take(.boarded(journey.legs[1]))
        drive.clock = Self.at("06:49:00")
        drive.trip.take(.gotOff(journey.legs[1]))
        #expect(drive.trip.timeline.steps[3].service?.scheduled == Self.at("06:55:00"))
        // Ten minutes on, the fix still Paddington's: still the 06:55, still off at 07:13:30.
        drive.tick("06:53:00")
        drive.tick("06:56:00")
        #expect(drive.trip.legIndex == 2)
        #expect(drive.trip.timeline.steps[3].service?.scheduled == Self.at("06:55:00"))
        #expect(drive.alerts.time("getoff.3") == Self.at("07:13:30"))
    }

    /// `metres` along the Bakerloo from Paddington towards Baker Street.
    static func alongBakerloo(_ metres: Double) -> Coordinate {
        PathProgress.point(along: metres, on: [paddington, bakerStreet])!
    }

    /// Go started (or the ride surfaced) five minutes into the 06:41, nobody tapped, and
    /// Go sees you riding: you got on when the train left, not when it noticed.
    @MainActor @Test func detectedBoardingCountsTheRideAlreadyDone() {
        let journey = Self.bakerloo
        let length = PathProgress.length(of: [Self.paddington, Self.bakerStreet])
        let start = Self.at("06:46:00")
        let drive = Drive(journey, at: start, boards: Self.bakerlooBoards(journey), fix: nil)
        #expect(drive.trip.legIndex == 1)
        // Moving along the line at 10 m/s from where five of eight minutes put you.
        for second in stride(from: 0.0, through: 12, by: 2) {
            drive.clock = start.addingTimeInterval(second)
            drive.fix = LiveTrip.Fix(coordinate: Self.alongBakerloo(length * 5 / 8 + second * 10), at: drive.clock)
            drive.trip.refresh()
        }
        #expect(drive.trip.boarded)
        #expect(drive.trip.yourDeparture?.scheduled == Self.at("06:41:00"))
        #expect(drive.trip.rideArrival == Self.at("06:49:00"))
        #expect(drive.trip.eta == Self.at("07:20:00"))
        #expect(drive.alerts.time("getoff.3") == Self.at("07:13:30"))
    }

    /// The platform's last fix came moments before the tap: it still says nothing about
    /// where you are once aboard, so the clock moves the ride on.
    @MainActor @Test func aFixJustBeforeTheTapDoesntHoldTheRide() {
        let journey = Self.bakerloo
        let drive = Drive(journey, at: Self.at("06:28:00"), boards: Self.bakerlooBoards(journey), fix: Self.paddington)
        drive.tick("06:28:00", at: Self.paddington)
        drive.tick("06:30:00", at: Self.paddington)
        drive.clock = Self.at("06:30:20")
        drive.trip.take(.boarded(journey.legs[1]))
        #expect(drive.trip.rideArrival == Self.at("06:38:00"))
        #expect(drive.trip.estimatedPosition != nil)
        // Ticking all ride with nothing new: alerts aren't sent again and again (up to
        // 06:36:30, when the get-off alert is due and leaves the plan).
        let sent = drive.alerts.schedules
        var clock = Self.at("06:30:22")
        while clock < Self.at("06:36:20") {
            drive.clock = clock
            drive.trip.refresh()
            clock = clock.addingTimeInterval(2)
        }
        #expect(drive.alerts.schedules == sent)
        #expect(drive.trip.eta == Self.at("07:08:00"))
        drive.tick("06:37:40")
        #expect(drive.trip.legIndex == 2)
    }

    /// An alert whose time has come by the time it's handed over isn't added again
    /// (the system has shown it, or is about to).
    @Test func alertsAlreadyDueAreNotAddedAgain() {
        let now = Self.at("06:36:30")
        let alerts = [TripAlert(id: "getoff.1", date: now.addingTimeInterval(0.5), title: "", body: ""),
                      TripAlert(id: "getoff.3", date: now.addingTimeInterval(600), title: "", body: "")]
        #expect(TripAlerts.toAdd(alerts, now: now).map(\.id) == ["getoff.3"])
    }
}

