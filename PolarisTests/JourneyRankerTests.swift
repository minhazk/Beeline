import Foundation
import Testing
@testable import Polaris

struct JourneyRankerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Leaves `leaves` minutes after t0 and arrives at `arrives`, walking `walk`
    /// minutes first, then riding these lines in equal parts.
    func journey(_ lines: [String], leaves: Double = 0, arrives: Double, walk: Double = 0, mode: LegMode = .tube) -> Journey {
        let start = t0 + leaves * 60
        var legs = [Leg(mode: .walk, fromName: "", toName: "", departure: start, arrival: start + walk * 60)]
        let ride = (arrives - leaves - walk) * 60 / Double(lines.count)
        for (i, line) in lines.enumerated() {
            let departure = start + walk * 60 + Double(i) * ride
            legs.append(Leg(mode: mode, line: line, fromName: "", toName: "", departure: departure, arrival: departure + ride))
        }
        return Journey(departure: start, arrival: t0 + arrives * 60, legs: legs,
                       sources: [SourceTag(provider: .tfl, variant: "Fastest")])
    }

    func order(_ ranked: JourneyRanker.Ranked) -> [String] { ranked.top.map(\.journey.routeSignature) }

    @Test func routesThroughClosuresStillHaveAResultAndMapWithoutALeadingRecommendation() {
        var route = journey(["Jubilee"], arrives: 27)
        let notice = ServiceNotice(title: "Station closed", detail: "Canary Wharf", severity: .closed,
                                   source: .tfl, leg: route.legs[1].id)
        route.notices = [notice]
        let ranked = JourneyRanker.rank([route], arriveBy: false)
        #expect(ranked.onlyBlockedRoutes && ranked.top.isEmpty)
        #expect(ranked.mapJourneys == [route])
        #expect(!JourneyRanker.rank([], arriveBy: false).onlyBlockedRoutes)

        var another = notice
        another.detail = "London Bridge"
        #expect(another.displayID != notice.displayID)
        another = notice
        another.leg = UUID()
        #expect(another.displayID == notice.displayID)
    }

    @Test func shelvesRoutesBeatenOnEverything() {
        let fast = journey(["Hammersmith & City", "Elizabeth"], arrives: 30)
        let slow = journey(["Northern", "DLR"], arrives: 39)
        let direct = journey(["135"], arrives: 45, mode: .bus)
        let ranked = JourneyRanker.rank([slow, direct, fast], arriveBy: false)
        #expect(order(ranked) == [fast.routeSignature, direct.routeSignature])
        // Same changes as `fast`, arrives later.
        #expect(ranked.more.map(\.journey.routeSignature) == [slow.routeSignature])
    }

    @Test func aMinuteLessWalkingNeverBeatsAnHour() {
        let tube = journey(["Victoria"], arrives: 30, walk: 8)
        let bus = journey(["N73"], arrives: 90, walk: 6, mode: .bus)
        let ranked = JourneyRanker.rank([bus, tube], arriveBy: false, sort: .leastWalking)
        #expect(order(ranked) == [tube.routeSignature])
        #expect(ranked.more.map(\.journey.routeSignature) == [bus.routeSignature])
    }

    @Test func muchLessWalkingWinsWhenAskedFor() {
        let walky = journey(["Central"], arrives: 30, walk: 16)
        let easy = journey(["Jubilee"], arrives: 36, walk: 3)
        #expect(order(JourneyRanker.rank([walky, easy], arriveBy: false, sort: .fastest)) == [walky.routeSignature, easy.routeSignature])
        #expect(order(JourneyRanker.rank([walky, easy], arriveBy: false, sort: .leastWalking)) == [easy.routeSignature, walky.routeSignature])
    }

    @Test func changingTheOrderNeverHidesTheBalancedPicks() {
        let routes = [journey(["Central"], arrives: 30, walk: 16), journey(["Jubilee"], arrives: 36, walk: 3),
                      journey(["Northern", "DLR"], arrives: 29), journey(["135"], arrives: 41, mode: .bus)]
        let balanced = Set(order(JourneyRanker.rank(routes, arriveBy: false, sort: .best)))
        for sort in SortOrder.allCases {
            #expect(balanced.isSubset(of: Set(order(JourneyRanker.rank(routes, arriveBy: false, sort: sort)))))
        }
    }

    @Test func fewestChangesBringsUpADirectRoute() {
        let quick = journey(["Northern", "DLR"], arrives: 29)
        let direct = journey(["135"], arrives: 50, mode: .bus)
        #expect(order(JourneyRanker.rank([quick, direct], arriveBy: false, sort: .best)) == [quick.routeSignature])
        #expect(order(JourneyRanker.rank([quick, direct], arriveBy: false, sort: .fewestChanges))
                == [direct.routeSignature, quick.routeSignature])
    }

    @Test func otherDeparturesSkipTheSameMinute() {
        let runs = [0.0, 0.5, 7].map { journey(["Northern", "DLR"], leaves: $0, arrives: $0 + 29) }
        #expect(JourneyRanker.rank(runs, arriveBy: false).top.first?.otherDepartures == [t0 + 420])
    }

    @Test func directRouteWinsWhenChangesMatter() {
        let change = journey(["Northern", "DLR"], arrives: 29)
        let direct = journey(["Jubilee"], arrives: 40)
        #expect(order(JourneyRanker.rank([change, direct], arriveBy: false, sort: .best)).first == change.routeSignature)
        #expect(order(JourneyRanker.rank([change, direct], arriveBy: false, sort: .fewestChanges)).first == direct.routeSignature)
    }

    @Test func laterDeparturesFoldIntoOneCard() {
        let runs = [0.0, 5, 10].map { journey(["Northern", "DLR"], leaves: $0, arrives: $0 + 29) }
        let ranked = JourneyRanker.rank(runs.reversed(), arriveBy: false)
        #expect(ranked.top.count == 1 && ranked.more.isEmpty)
        #expect(ranked.top[0].journey.departure == t0)
        #expect(ranked.top[0].otherDepartures == [t0 + 300, t0 + 600])
    }

    @Test func cardCreditsEverySourceThatFoundTheLines() {
        var google = journey(["Northern", "DLR"], arrives: 29)
        google.sources = [SourceTag(provider: .google, variant: "Fastest")]
        var transitous = journey(["Northern", "DLR"], leaves: 8, arrives: 37)
        transitous.sources = [SourceTag(provider: .transitous, variant: "Fastest")]
        #expect(JourneyRanker.rank([google, transitous], arriveBy: false).top.first?.providers == [.google, .transitous])
    }

    @Test func farSlowerRoutesFoldAway() {
        let quick = journey(["Metropolitan", "Elizabeth"], arrives: 29, walk: 13)
        let slow = journey(["Hammersmith & City", "135"], arrives: 49, walk: 7)
        let ranked = JourneyRanker.rank([quick, slow], arriveBy: false)
        #expect(order(ranked) == [quick.routeSignature])
        #expect(ranked.more.count == 1)
    }

    @Test func filtersHideRoutesAndCountThem() {
        let tube = journey(["Northern", "DLR"], arrives: 29)
        let bus = journey(["135"], arrives: 45, mode: .bus)
        var filter = RouteFilter(avoided: [.bus])
        var ranked = JourneyRanker.rank([tube, bus], arriveBy: false, filter: filter)
        #expect(order(ranked) == [tube.routeSignature] && ranked.hidden == 1)

        filter = RouteFilter(maxChanges: 0)
        ranked = JourneyRanker.rank([tube, bus], arriveBy: false, filter: filter)
        #expect(order(ranked) == [bus.routeSignature] && ranked.hidden == 1)
    }

    @Test func arriveByPrefersLatestDeparture() {
        let early = journey(["25"], leaves: 0, arrives: 25, mode: .bus)
        let late = journey(["Central"], leaves: 10, arrives: 25)
        #expect(order(JourneyRanker.rank([early, late], arriveBy: true)).first == late.routeSignature)
    }
}
