import Foundation
import Testing
@testable import Beeline

struct JourneyMergerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func journey(_ lines: [(LegMode, String)], boards: TimeInterval, arrives: TimeInterval,
                 by provider: ProviderID, _ variant: String = "Fastest", fare: String? = nil) -> Journey {
        let legs = lines.enumerated().map { i, line in
            Leg(mode: line.0, line: line.1, fromName: "", toName: "",
                departure: t0 + boards + Double(i) * 300, arrival: t0 + boards + Double(i + 1) * 300)
        }
        return Journey(departure: t0 + boards - 120, arrival: t0 + arrives, legs: legs,
                       sources: [SourceTag(provider: provider, variant: variant)], fare: fare)
    }

    @Test func sameRouteFromDifferentSourcesMerges() {
        let tfl = journey([(.tube, "Northern"), (.dlr, "DLR")], boards: 300, arrives: 2400, by: .tfl)
        // Google calls the same lines slightly differently and is a minute out.
        let google = journey([(.tube, "Northern line"), (.dlr, "DLR")], boards: 360, arrives: 2460, by: .google, fare: "£2.80")
        let merged = JourneyMerger.merge([google, tfl])
        #expect(merged.count == 1)
        #expect(merged[0].providers == [.tfl, .google])
        #expect(merged[0].fare == "£2.80")
    }

    @Test func elizabethLineMatchesWhetherRailOrSubway() {
        let a = journey([(.elizabeth, "Elizabeth line")], boards: 300, arrives: 1500, by: .transitous)
        let b = journey([(.rail, "Elizabeth line")], boards: 300, arrives: 1500, by: .google)
        #expect(JourneyMerger.merge([a, b]).count == 1)
    }

    @Test func laterDepartureOfSameRouteStaysSeparate() {
        let a = journey([(.bus, "25")], boards: 300, arrives: 1500, by: .tfl)
        let b = journey([(.bus, "25")], boards: 900, arrives: 2100, by: .tfl)
        #expect(JourneyMerger.merge([a, b]).count == 2)
    }
}
