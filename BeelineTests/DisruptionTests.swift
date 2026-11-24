import Foundation
import Testing
@testable import Beeline

/// TfL's network status checked against routes from any source. Recorded on
/// Sunday 8 November 2026, when Elizabeth line trains weren't stopping at Canary
/// Wharf, the Windrush and Mildmay were part closed, and Burnt Oak was shut.
struct DisruptionTests {
    static let afternoon = Time.iso("2026-11-08T16:00:00Z")!

    static func status() throws -> NetworkStatus {
        try NetworkStatus.parse(lines: ProviderParsingTests.fixture("tfl-line-status"),
                                stops: ProviderParsingTests.fixture("tfl-stop-disruptions"))
    }

    static func ride(_ mode: LegMode, _ line: String, from: String, to: String, via: [String] = [], at: Date = afternoon) -> Leg {
        Leg(mode: mode, line: line, fromName: from, toName: to, departure: at, arrival: at.addingTimeInterval(600), intermediateStops: via)
    }

    @Test func readsTheNetwork() throws {
        let status = try Self.status()
        #expect(status.lines.contains { $0.name == "Jubilee" && $0.severity == 9 })
        let wharf = try #require(status.stops.first { $0.key == "canarywharf" })
        #expect(wharf.mode == .elizabeth)
        #expect(wharf.line == nil)
        #expect(!wharf.isClosure)
        // Step-free notes and interchange messages aren't closures.
        #expect(status.stops.allSatisfy { !$0.description.contains("No Step Free Access") })
        #expect(status.stops.contains { $0.line == "windrush" && $0.key == "surreyquays" })
        #expect(NetworkStatus.stationKey("Shepherds Bush Rail Station") == NetworkStatus.stationKey("Shepherd's Bush"))
        #expect(NetworkStatus.stationKey("Kensington (Olympia) Rail Station") == NetworkStatus.stationKey("Kensington (Olympia)"))
    }

    @Test func flagsARouteThroughTheClosedStation() throws {
        let status = try Self.status()
        // The Elizabeth line to Canary Wharf, as a planner that didn't know would suggest.
        let notices = status.notices(for: Self.ride(.elizabeth, "Elizabeth line", from: "Liverpool Street", to: "Canary Wharf", via: ["Whitechapel"]))
        let notice = try #require(notices.first)
        #expect(notice.severity == .closed)
        #expect(notice.title == "Canary Wharf part closed (Elizabeth line)")
        #expect(notice.detail.contains("not stopping"))
        #expect(notice.source == .tfl)
        // Going through without stopping is fine.
        #expect(status.notices(for: Self.ride(.elizabeth, "Elizabeth line", from: "Whitechapel", to: "Abbey Wood",
                                              via: ["Canary Wharf", "Custom House"])).isEmpty)
        // So is the DLR there; the Jubilee only has minor delays at its far end.
        #expect(status.notices(for: Self.ride(.dlr, "DLR", from: "Bank", to: "Canary Wharf")).isEmpty)
        let jubilee = status.notices(for: Self.ride(.tube, "Jubilee", from: "London Bridge", to: "Canary Wharf"))
        #expect(jubilee.map(\.severity) == [.minor])
        #expect(jubilee.first?.title == "Minor delays on the Jubilee")
    }

    @Test func tellsAStretchFromItsEnd() throws {
        let status = try Self.status()
        // No Windrush service between Surrey Quays and Clapham Junction: riding within it won't work…
        let within = status.notices(for: Self.ride(.overground, "Windrush", from: "Surrey Quays", to: "Peckham Rye", via: ["Queens Road Peckham"]))
        #expect(within.first?.severity == .closed)
        #expect(within.first?.title == "Part closure on the Windrush")
        // …but Surrey Quays still has trains northbound, so riding from it is only a warning.
        #expect(status.notices(for: Self.ride(.overground, "Windrush", from: "Surrey Quays", to: "Canada Water")).map(\.severity) == [.delays])
        // The Mildmay's closure is listed at the same stations, but isn't about the Windrush.
        #expect(!within.contains { $0.detail.hasPrefix("MILDMAY") })
        #expect(status.notices(for: Self.ride(.overground, "Mildmay", from: "Willesden Junction", to: "Shepherd's Bush")).first?.severity == .closed)
        // And it's only for today.
        let tuesday = Self.ride(.overground, "Windrush", from: "Surrey Quays", to: "Peckham Rye", at: Time.iso("2026-11-10T09:00:00Z")!)
        #expect(status.notices(for: tuesday).allSatisfy { $0.severity != .closed })
    }

    @Test func aStationShutAndOneShutOneWay() throws {
        let status = try Self.status()
        let burntOak = status.notices(for: Self.ride(.tube, "Northern", from: "Colindale", to: "Burnt Oak"))
        #expect(burntOak.first?.title == "Burnt Oak station closed")
        #expect(burntOak.first?.severity == .closed)
        // Westbound trains not calling at Barons Court leaves the eastbound ones: a warning, not a closure.
        #expect(status.notices(for: Self.ride(.tube, "Piccadilly", from: "Barons Court", to: "Green Park")).map(\.severity) == [.delays])
        // A line closed for the day.
        let city = status.notices(for: Self.ride(.tube, "Waterloo & City", from: "Waterloo", to: "Bank"))
        #expect(city.first?.severity == .closed)
    }

    @Test func aRouteThroughAClosureNeverLeads() throws {
        let status = try Self.status()
        func journey(_ leg: Leg, minutes: Double, from provider: ProviderID) -> Journey {
            var journey = Journey(departure: Self.afternoon, arrival: Self.afternoon.addingTimeInterval(minutes * 60), legs: [leg],
                                  sources: [SourceTag(provider: provider, variant: "Fastest")])
            journey.notices = status.notices(for: journey)
            return journey
        }
        // Google's quicker route stops at Canary Wharf on the Elizabeth line; TfL's goes by DLR.
        let elizabeth = journey(Self.ride(.elizabeth, "Elizabeth line", from: "Liverpool Street", to: "Canary Wharf"), minutes: 12, from: .google)
        let dlr = journey(Self.ride(.dlr, "DLR", from: "Bank", to: "Canary Wharf"), minutes: 19, from: .tfl)
        #expect(elizabeth.isBlocked)
        #expect(!dlr.isBlocked)
        let ranked = JourneyRanker.rank([elizabeth, dlr], arriveBy: false)
        #expect(ranked.top.map(\.journey.id) == [dlr.id])
        #expect(ranked.more.map(\.journey.id) == [elizabeth.id])
    }
}
