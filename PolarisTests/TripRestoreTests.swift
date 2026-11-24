import Foundation
import Testing
@testable import Polaris

/// Polaris closed mid-trip and opened again: the trip is kept, picked up where it got to,
/// caught up by the clock, and carries on with the same Live Activity and alerts.
@MainActor
struct TripRestoreTests {
    typealias T = LiveTripTests
    static func at(_ clock: String) -> Date { T.at(clock) }

    /// The Live Activity as Go drives it, kept in a list instead of ActivityKit.
    @MainActor final class RecordedActivity: TripActivityDriving {
        var starts: [Bool] = []
        var updates = 0
        var ended = 0
        func start(destination: String, state: TripActivityAttributes.ContentState, adopt: Bool) { starts.append(adopt) }
        func update(_ state: TripActivityAttributes.ContentState) { updates += 1 }
        func end() { ended += 1 }
    }

    /// A store of its own in the temporary folder, so tests never touch the app's.
    static func store() -> TripStore {
        TripStore(url: FileManager.default.temporaryDirectory.appending(path: "trip-\(UUID().uuidString).json"))
    }

    /// A trip opened again from `saved`, with the test's clock, fix and boards.
    @MainActor final class Reopened {
        var clock: Date
        var fix: LiveTrip.Fix?
        var boards: [UUID: DepartureBoard]
        let alerts = T.RecordedAlerts()
        let activity = RecordedActivity()
        let location = LocationService()
        var loaded: [UUID] = []
        let store: TripStore
        var trip: LiveTrip!

        init(_ saved: SavedTrip, at time: Date, boards: [UUID: DepartureBoard], fix: LiveTrip.Fix?, store: TripStore,
             search: ReplanSearch.Search? = nil) {
            clock = time
            self.boards = boards
            self.fix = fix
            self.store = store
            trip = LiveTrip(resuming: saved, location: location, departures: DepartureStore(),
                            clock: { [weak self] in self?.clock ?? time }, fix: { [weak self] in self?.fix },
                            boards: { [weak self] in self?.boards[$0.id] }, loadBoard: { [weak self] in self?.loaded.append($0.id) },
                            routeWalk: { _, _ in nil }, alerts: alerts, search: search, isOnline: { true },
                            activity: activity, store: store)
        }

        func tick(_ time: String, at place: Coordinate? = nil) {
            clock = TripRestoreTests.at(time)
            if let place { fix = LiveTrip.Fix(coordinate: place, at: clock) }
            trip.refresh()
        }
    }

    /// The sample Bakerloo trip as far as getting on the 06:30 (a tap at 06:30:20), then Polaris
    /// closed: what was saved. Gets off 06:38, the 06:43 Jubilee, there 07:08.
    static func savedOnTheEarlyBakerloo(store: TripStore? = nil) throws -> (SavedTrip, Journey) {
        let journey = T.bakerloo
        let drive = T.Drive(journey, at: at("06:25:00"), boards: T.bakerlooBoards(journey), fix: T.start)
        drive.tick("06:28:00", at: T.paddington)
        drive.clock = at("06:30:20")
        drive.trip.take(.boarded(journey.legs[1]))
        let saved = drive.trip.saved
        try #require(saved.log.boardings[1] != nil && saved.arrival == at("07:08:00"))
        store?.save(saved)
        return (saved, journey)
    }

    // MARK: Saving

    /// A real recorded TfL journey, mid-trip, through the file and back: the same journey (ids,
    /// times, paths, line names), so the log and timeline still find their legs and matching
    /// across sources still sees the same route.
    @Test func savedTripRoundTripsARecordedJourney() throws {
        let journeys = try TfLProvider.parse(ProviderParsingTests.fixture("tfl-journeys"), variant: "Fastest")
        var journey = try #require(journeys.first)
        journey.notices.append(ServiceNotice(title: "Minor delays on the Northern", detail: "Signal failure.", severity: .delays,
                                             source: .tfl, leg: journey.legs[0].id))
        let firstRide = journey.legs.firstIndex { $0.mode.isTransit }
        let ride = try #require(firstRide)
        var log = TripLog(began: journey.departure.addingTimeInterval(-90.25))
        log.boardings[ride] = TripLog.Boarding(at: journey.legs[ride].departure.addingTimeInterval(12.5), departure: Departure(
            id: "tfl-123", line: "Northern", mode: .tube, lineColor: RGB(hex: "000000"), headsign: "Morden", stopName: "King's Cross",
            stopCoordinate: journey.legs[ride].start!, scheduled: journey.legs[ride].departure, expected: journey.legs[ride].departure,
            isRealtime: true, isCancelled: false, platform: "4", arrivalThere: journey.legs[ride].arrival))
        log.ended[0] = journey.legs[0].arrival
        let query = JourneyQuery(origin: Place(name: "King's Cross", coordinate: .init(latitude: 51.5308, longitude: -0.1238)),
                                 destination: Place(name: "Canary Wharf", coordinate: .init(latitude: 51.5035, longitude: -0.0187)),
                                 time: .departAt(journey.departure))
        var watch = Replan.Watch()
        watch.asked(.longWait(leg: 3, wait: 600), now: journey.departure, usedGoogle: true, answered: true)
        watch.declined(.cancelled(leg: 3))
        let saved = SavedTrip(journey: journey, query: query, legIndex: ride, log: log, replanWatch: watch,
                              checkedWaits: ["wait.3"], arrival: journey.arrival)

        let store = Self.store()
        defer { store.clear() }
        store.save(saved)
        let back = try #require(store.load())
        #expect(back == saved)
        #expect(back.journey.id == journey.id)
        #expect(back.journey.legs.map(\.id) == journey.legs.map(\.id))
        #expect(back.journey.routeSignature == journey.routeSignature)
        #expect(back.journey.legs.map(\.path) == journey.legs.map(\.path))
        #expect(back.log.boardings[ride]?.departure?.id == "tfl-123")
        #expect(back.replanWatch.sends == 1 && back.replanWatch.googleRequests == 1)
        #expect(back.replanWatch.settled == ["wait.3", "cancelled.3"])
        // An unreadable file is no trip, not a crash.
        try Data("{not json".utf8).write(to: store.url)
        #expect(store.load() == nil)
    }

    /// Saved when something happens (a boarding), not on every tick.
    @Test func savesOnEventsNotTicks() throws {
        let store = Self.store()
        defer { store.clear() }
        let journey = T.bakerloo
        let reopened = Reopened(SavedTrip(journey: journey, query: JourneyQuery(origin: Place(name: "Norfolk Square", coordinate: T.start),
                                                                              destination: Place(name: "One Canada Square", coordinate: T.canadaSquare),
                                                                              time: .leaveNow),
                                          legIndex: 1, log: TripLog(began: Self.at("06:25:00")), replanWatch: .init(),
                                          checkedWaits: [], arrival: Self.at("07:20:00")),
                                at: Self.at("06:28:00"), boards: T.bakerlooBoards(journey),
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:28:00")), store: store)
        let trip = reopened.trip!
        trip.catchUp()
        reopened.tick("06:28:02")
        reopened.tick("06:28:04")
        reopened.tick("06:28:06")
        #expect(trip.saveCount == 0)
        reopened.clock = Self.at("06:30:20")
        trip.take(.boarded(journey.legs[1]))
        #expect(trip.saveCount == 1)
        #expect(store.load()?.log.boardings[1] != nil)
        reopened.tick("06:30:22")
        reopened.tick("06:30:24")
        #expect(trip.saveCount == 1)
    }

    // MARK: Picking it up

    /// Opened five minutes later, still on the train: the same ride, the same train, the same
    /// times. One Live Activity, adopted; the alerts rescheduled once.
    @Test func reopenedMidRide() async throws {
        let store = Self.store()
        defer { store.clear() }
        let (saved, journey) = try Self.savedOnTheEarlyBakerloo(store: store)
        // Underground: the phone still holds Paddington's fix from before you got on.
        let reopened = Reopened(try #require(store.load()), at: Self.at("06:35:00"), boards: [:],
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:28:00")), store: store)
        let trip = reopened.trip!
        trip.start()
        #expect(trip.isResumed)
        #expect(trip.legIndex == 1 && trip.boarded)
        #expect(trip.yourDeparture?.scheduled == Self.at("06:30:00"))
        #expect(trip.rideArrival == Self.at("06:38:00"))
        #expect(trip.log == saved.log)
        #expect(reopened.activity.starts == [true])
        #expect(reopened.alerts.schedules == 1)
        #expect(reopened.alerts.time("getoff.1") == Self.at("06:36:30"))
        #expect(reopened.alerts.offered == nil)
        // Later rides' boards are fetched once each.
        await Task.yield()
        #expect(reopened.loaded.contains(journey.legs[3].id))
        #expect(Set(reopened.loaded).count == reopened.loaded.count)
        // End: nothing left to pick up.
        trip.stop()
        #expect(!store.exists)
        #expect(reopened.activity.ended == 1)
    }

    /// Opened at 06:45, after the train got in at 06:38: on to the change without a tap, the
    /// ride ended when it got in (not at 06:45), so the 06:43 Jubilee and 07:08 still stand.
    /// No alert for the ride that's done.
    @Test func reopenedAfterTheRideEnded() async throws {
        let store = Self.store()
        defer { store.clear() }
        let (_, journey) = try Self.savedOnTheEarlyBakerloo(store: store)
        let reopened = Reopened(try #require(store.load()), at: Self.at("06:45:00"), boards: T.bakerlooBoards(journey),
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:28:00")), store: store)
        let trip = reopened.trip!
        trip.start()
        #expect(trip.legIndex == 2)
        #expect(trip.log.ended[1] == Self.at("06:38:00"))
        #expect(trip.timeline.steps[3].service?.scheduled == Self.at("06:43:00"))
        #expect(trip.eta == Self.at("07:08:00"))
        #expect(reopened.activity.starts == [true])
        #expect(reopened.alerts.schedules == 1)
        #expect(reopened.alerts.time("getoff.1") == nil)
        #expect(reopened.alerts.time("getoff.3") == Self.at("07:01:30"))
        // Saved again: the leg ended counts.
        #expect(store.load()?.legIndex == 2)
        trip.stop()
    }

    /// Opened at 07:20, out at One Canada Square: on the last leg, there, with no alerts left. As on
    /// a phone, the first fix comes a moment after Go starts tracking, not at launch.
    @Test func reopenedAfterArriving() throws {
        let store = Self.store()
        defer { store.clear() }
        let (saved, journey) = try Self.savedOnTheEarlyBakerloo(store: store)
        #expect(saved.isResumable(now: Self.at("07:20:00")))
        let reopened = Reopened(try #require(store.load()), at: Self.at("07:20:00"), boards: T.bakerlooBoards(journey),
                                fix: nil, store: store)
        let trip = reopened.trip!
        let router = Router()
        router.resume(trip)
        trip.start()
        // No fix yet: the clock alone ends the Bakerloo; the change walk waits to be seen.
        #expect(trip.legIndex == 2)
        reopened.tick("07:20:02", at: T.canadaSquare)
        #expect(trip.legIndex == journey.legs.count - 1 && trip.isLastLeg)
        #expect(trip.log.ended[1] == Self.at("06:38:00"))
        #expect(trip.log.ended[3] == Self.at("07:03:00"))
        #expect(reopened.alerts.pending.isEmpty)
        #expect(reopened.activity.starts == [true])
        reopened.tick("07:20:06", at: T.canadaSquare)
        reopened.tick("07:20:10", at: T.canadaSquare)
        #expect(router.trip == nil)
        #expect(router.tripNotice?.reason == .arrived)
        #expect(router.tripNotice?.destination == saved.query.destination.name)
        #expect(!reopened.location.isTracking)
        #expect(reopened.activity.ended == 1)
        #expect(!store.exists)
        reopened.tick("07:20:12", at: T.canadaSquare)
        #expect(!store.exists && reopened.activity.ended == 1)
    }

    @Test func aTripLeftRunningWithoutLocationExpiresWithoutClaimingArrival() throws {
        let store = Self.store()
        defer { store.clear() }
        let (saved, journey) = try Self.savedOnTheEarlyBakerloo(store: store)
        let reopened = Reopened(saved, at: Self.at("06:35:00"), boards: [:], fix: nil, store: store)
        let trip = reopened.trip!
        let router = Router()
        router.resume(trip)
        trip.start()
        reopened.clock = journey.arrival.addingTimeInterval(LiveTrip.expiryGrace + 1)
        trip.refresh()
        #expect(router.tripNotice?.reason == .expired)
        #expect(router.trip == nil && !reopened.location.isTracking)
        #expect(!store.exists && reopened.alerts.pending.isEmpty && reopened.activity.ended == 1)
    }

    /// Opened 20 seconds before "Get off at Baker Street": the alert handed over before Polaris
    /// closed is still pending, so it stays (inside the half-minute a new one would need).
    @Test func reopenedJustBeforeAnAlertKeepsIt() throws {
        let store = Self.store()
        defer { store.clear() }
        let (_, journey) = try Self.savedOnTheEarlyBakerloo(store: store)
        let reopened = Reopened(try #require(store.load()), at: Self.at("06:36:10"), boards: T.bakerlooBoards(journey),
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:28:00")), store: store)
        reopened.trip.start()
        #expect(reopened.alerts.schedules == 1)
        #expect(reopened.alerts.time("getoff.1") == Self.at("06:36:30"))
        reopened.trip.stop()
    }

    /// Long after (more than half an hour past its arrival), the trip isn't picked up: the file
    /// goes (and with it the Live Activity and the alerts, at launch).
    @Test func longAfterIsDropped() throws {
        let store = Self.store()
        defer { store.clear() }
        let (saved, _) = try Self.savedOnTheEarlyBakerloo(store: store)
        #expect(saved.isResumable(now: Self.at("07:38:00")))
        #expect(!saved.isResumable(now: Self.at("07:38:01")))
        #expect(!saved.isResumable(now: Self.at("18:00:00")))
        var other = saved
        other.version = SavedTrip.currentVersion + 1
        #expect(!other.isResumable(now: Self.at("06:35:00")))
        TripResume.decide(store: store, now: Self.at("09:00:00"))
        #expect(!store.exists)
        #expect(TripResume.take(store: store, now: Self.at("09:00:00")) == nil)
        // Still in time: kept for the sheet to take, once.
        store.save(saved)
        TripResume.decide(store: store, now: Self.at("06:40:00"))
        #expect(TripResume.take(store: store, now: Self.at("06:40:00")) == saved)
        #expect(TripResume.take(store: store, now: Self.at("06:40:00")) == nil)
        #expect(store.exists)
    }

    // MARK: Re-planning across a relaunch

    /// Picked up with a reason to re-plan already there (early onto the Bakerloo, a long wait at
    /// Baker Street): the restore asks nothing. The next event (out at Baker Street) can.
    @Test func restoreNeverSearches() async throws {
        let journey = ReplanTests.toIsland
        // Same trip shape, to the island, with its bus board, early on the 06:26.
        let drive = T.Drive(journey, at: Self.at("06:22:00"), boards: ReplanTests.boards(journey), fix: T.paddington)
        drive.tick("06:22:00", at: T.paddington)
        drive.clock = Self.at("06:26:20")
        drive.trip.take(.boarded(journey.legs[1]))
        #expect(drive.trip.saved.legIndex == 1)
        let planner = ReplanTests.Planner([ReplanTests.dlr])
        let store = Self.store()
        defer { store.clear() }
        // As in the app, no boards at first: they come in a moment after the restore.
        let reopened = Reopened(drive.trip.saved, at: Self.at("06:28:00"), boards: [:],
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:22:00")), store: store,
                                search: planner.search)
        reopened.trip.start()
        reopened.tick("06:28:02")
        reopened.boards = ReplanTests.boards(journey)
        reopened.tick("06:28:04")
        reopened.tick("06:28:06")
        await reopened.trip.replanTask?.value
        #expect(planner.queries.isEmpty)
        reopened.tick("06:34:10", at: T.bakerStreet)
        await reopened.trip.replanTask?.value
        #expect(planner.queries.count == 1)
        reopened.trip.stop()
    }

    /// The trip's search count and a declined offer come back with it: "Keep my route" stays kept.
    @Test func capsAndDeclinedReasonsSurvive() async throws {
        let first = ReplanTests.Planner([ReplanTests.dlr])
        let drive = await ReplanTests.early(with: first)
        drive.trip.keepRoute()
        let saved = drive.trip.saved
        #expect(saved.replanWatch.sends == 1)
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SavedTrip.self, from: data)
        #expect(back.replanWatch == drive.trip.replanWatch)

        let planner = ReplanTests.Planner([ReplanTests.dlr])
        let store = Self.store()
        defer { store.clear() }
        let journey = back.journey
        let reopened = Reopened(back, at: Self.at("06:30:00"), boards: ReplanTests.boards(journey),
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:22:00")), store: store,
                                search: planner.search)
        let trip = reopened.trip!
        trip.start()
        #expect(trip.replanWatch == drive.trip.replanWatch)
        // Out at Baker Street with the same long wait: declined, so not asked again.
        reopened.tick("06:34:10", at: T.bakerStreet)
        reopened.tick("06:39:30")
        await trip.replanTask?.value
        #expect(planner.queries.isEmpty)
        #expect(trip.offer == nil)
        trip.stop()
    }

    // MARK: Review fixes

    /// Waiting at Paddington for the 06:41, ten minutes late on the board, then closed; got on
    /// underground with no signal and reopened at 06:49:30, the timetable's arrival. With no
    /// board yet and no boarding seen, the clock mustn't end a ride you may be still on: it
    /// waits for the board, which says the train left 06:51.
    @Test func lateUnseenRideIsNotEndedByTheTimetable() throws {
        let journey = T.bakerloo
        var late = T.bakerlooBoards(journey)
        var board = try #require(late[journey.legs[1].id])
        let index = try #require(board.departures.firstIndex { $0.id == board.plannedID })
        board.departures[index].expected = Self.at("06:51:00")
        board.departures[index].arrivalThere = Self.at("06:59:00")
        late[journey.legs[1].id] = board
        let drive = T.Drive(journey, at: Self.at("06:38:00"), boards: late, fix: T.paddington)
        drive.tick("06:40:00", at: T.paddington)
        #expect(drive.trip.legIndex == 1 && drive.trip.isWaiting)
        let store = Self.store()
        defer { store.clear() }
        let reopened = Reopened(drive.trip.saved, at: Self.at("06:49:30"), boards: [:],
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:40:00")), store: store)
        let trip = reopened.trip!
        trip.start()
        #expect(trip.legIndex == 1)
        #expect(trip.log.ended[1] == nil)
        // The board comes in: the 06:51, at Baker Street 06:59.
        reopened.boards = late
        reopened.tick("06:49:32")
        #expect(trip.legIndex == 1)
        #expect(trip.rideArrival == Self.at("06:59:00"))
        trip.stop()
    }

    /// A board the restore asked for never comes (no signal): after a minute the quiet ends, and
    /// the event that ends it (out at Baker Street) is still looked at, not swallowed.
    @Test func quietTimeoutKeepsTheEvent() async throws {
        let journey = ReplanTests.toIsland
        let drive = T.Drive(journey, at: Self.at("06:22:00"), boards: ReplanTests.boards(journey), fix: T.paddington)
        drive.tick("06:22:00", at: T.paddington)
        drive.clock = Self.at("06:26:20")
        drive.trip.take(.boarded(journey.legs[1]))
        var boards = ReplanTests.boards(journey)
        boards[journey.legs[1].id] = nil
        let planner = ReplanTests.Planner([ReplanTests.dlr])
        let store = Self.store()
        defer { store.clear() }
        let reopened = Reopened(drive.trip.saved, at: Self.at("06:28:00"), boards: boards,
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:22:00")), store: store,
                                search: planner.search)
        reopened.trip.start()
        reopened.tick("06:28:02")
        await reopened.trip.replanTask?.value
        #expect(planner.queries.isEmpty)
        reopened.tick("06:34:10", at: T.bakerStreet)
        await reopened.trip.replanTask?.value
        #expect(planner.queries.count == 1)
        reopened.trip.stop()
    }

    /// Launched in the background and shown much later: the age is checked again as the sheet
    /// takes the trip, and a stale one is dropped then.
    @Test func takeChecksTheAgeAgain() throws {
        let store = Self.store()
        defer { store.clear() }
        let (saved, _) = try Self.savedOnTheEarlyBakerloo(store: store)
        TripResume.decide(store: store, now: Self.at("06:40:00"))
        #expect(TripResume.take(store: store, now: Self.at("09:00:00")) == nil)
        #expect(!store.exists)
        store.save(saved)
        TripResume.decide(store: store, now: Self.at("06:40:00"))
        #expect(TripResume.take(store: store, now: Self.at("06:41:00")) == saved)
    }

    /// An unreadable file at launch is dropped.
    @Test func decideDeletesACorruptFile() throws {
        let store = Self.store()
        defer { store.clear() }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        TripResume.decide(store: store, now: Self.at("06:40:00"))
        #expect(!store.exists)
        #expect(TripResume.take(store: store, now: Self.at("06:40:00")) == nil)
    }

    /// Keep my route tapped on the notification that opens Polaris cold: once the trip is back,
    /// that reason is declined (and saved). Switch can't be done (the offer wasn't kept), so Go
    /// says it has gone.
    @Test func offerTappedFromAColdLaunch() async throws {
        let drive = await ReplanTests.early(with: ReplanTests.Planner([ReplanTests.dlr]))
        let saved = drive.trip.saved
        let key = try #require(saved.offerKey)
        let store = Self.store()
        defer { store.clear() }
        TripResume.hold(.keep)
        let reopened = Reopened(saved, at: Self.at("06:27:00"), boards: ReplanTests.boards(saved.journey),
                                fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:22:00")), store: store)
        reopened.trip.start()
        TripResume.applyHeld(to: reopened.trip)
        #expect(reopened.trip.replanWatch.settled.contains(key))
        // Kept: the offer's reason is settled (the search that found it already did that) and
        // the saved trip no longer carries an offer for a later tap to act on.
        #expect(store.load()?.offerKey == nil)
        #expect(store.load()?.replanWatch.settled.contains(key) == true)
        reopened.trip.stop()

        TripResume.hold(.switch)
        let again = Reopened(saved, at: Self.at("06:27:00"), boards: ReplanTests.boards(saved.journey),
                             fix: LiveTrip.Fix(coordinate: T.paddington, at: Self.at("06:22:00")), store: store)
        again.trip.start()
        TripResume.applyHeld(to: again.trip)
        #expect(again.trip.replan == .said(Replan.Message.offerGone))
        #expect(again.trip.journey == saved.journey)
        again.trip.stop()
    }
}
