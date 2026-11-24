import SwiftUI
import Testing
@testable import Beeline

/// Where the sheet rests on the Duo as the phone folds, opens and turns, and what is remembered.
/// Serialized: the put-away choice lives in the shared defaults.
@MainActor @Suite(.serialized)
struct RouterTests {
    init() { UserDefaults.standard.removeObject(forKey: "wholeMap") }

    private func onTheCover() -> Router {
        let router = Router()
        router.windowSize = CGSize(width: 466, height: 678)
        return router
    }

    private func open(_ router: Router) {
        router.windowSize = CGSize(width: 951, height: 669)
        router.foldX = 475
    }

    private func close(_ router: Router) {
        router.windowSize = CGSize(width: 466, height: 678)
        router.foldX = nil
        router.foldY = nil
    }

    private func turnTall(_ router: Router) {
        router.windowSize = CGSize(width: 669, height: 951)
        router.foldX = nil
        router.foldY = 475
    }

    @Test func putAwayOnTheCoverStaysPutAwayThroughAFold() {
        let router = onTheCover()
        router.picked(Router.low)
        open(router)
        #expect(router.detent == Router.low)
        #expect(!router.isPane)
        close(router)
        #expect(router.detent == Router.low)
    }

    @Test func bringingThePaneUpWideFoldsToTheSheet() {
        let router = onTheCover()
        router.picked(Router.low)
        open(router)
        router.toggleWholeMap()
        #expect(router.isPane)
        close(router)
        #expect(router.detent == .medium)
    }

    @Test func putAwayIsRememberedForTheNextLaunch() {
        let router = onTheCover()
        router.picked(Router.low)
        // A page asking for its rest is not the person choosing one.
        router.settle(.medium)
        #expect(Router().detent == Router.low)
        router.picked(Router.compact)
        #expect(Router().detent == .medium)
    }

    @Test func turnedTallThereIsNoLowRest() {
        let router = onTheCover()
        router.picked(Router.low)
        open(router)
        turnTall(router)
        #expect(router.detent == Router.compact)
        // Back where there is one, it is put away again.
        close(router)
        #expect(router.detent == Router.low)
    }

    @Test func fewRestsEachWithAJob() {
        let router = onTheCover()
        #expect(router.detents == [Router.low, .medium, .large])
        open(router)
        // Up or put away; a page that holds little keeps its own height.
        #expect(router.detents == [Router.low, Router.paneFull])
        router.settle(.medium, wide: .medium)
        #expect(router.detents == [Router.low, .medium, Router.paneFull])
        turnTall(router)
        #expect(router.detents == [Router.compact, .medium, .large])
    }

    @Test func goTurnedTallRestsAThirdUp() {
        let router = onTheCover()
        turnTall(router)
        router.trip = trip()
        router.settle(router.goRest)
        #expect(router.goRest != Router.compact)
        #expect(router.detent == router.goRest)
        #expect(router.restHeight.map { $0 > 280 && $0 < 330 } == true)
        // Folded, Go's rest is the 210 pt one, where the step and its button show.
        close(router)
        #expect(router.detent == Router.compact)
    }

    private func trip() -> LiveTrip {
        LiveTrip(journey: LiveTripTests.journey,
                 query: JourneyQuery(origin: Place(name: "Start", coordinate: LiveTripTests.a), destination: Place(name: "D", coordinate: LiveTripTests.d), time: .leaveNow),
                 location: LocationService(), departures: DepartureStore())
    }

    @Test func goFoldedKeepsTheStepInView() {
        let router = onTheCover()
        open(router)
        router.trip = trip()
        router.settle(router.goRest)
        // The whole map wide open during Go, then folded.
        router.toggleWholeMap()
        #expect(router.detent == Router.low)
        close(router)
        #expect(router.detent == Router.compact)
        #expect(!router.detents.contains(Router.low))
    }
}
