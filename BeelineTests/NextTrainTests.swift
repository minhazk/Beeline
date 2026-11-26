import Foundation
import Testing
@testable import Beeline

/// The next-train Live Activity: the JSON the alerts server pushes (the same contract file its
/// tests read), which trains it shows, and how a departure board becomes one.
@MainActor
struct NextTrainTests {
    struct Contract: Decodable {
        var attributes: NextTrainAttributes
        var state: NextTrainAttributes.ContentState

        enum CodingKeys: String, CodingKey { case attributes, state = "content-state" }
    }

    static func contract() throws -> Contract {
        try JSONDecoder().decode(Contract.self, from: ProviderParsingTests.fixture("next-train-contract"))
    }

    @Test func theServersJSONDecodes() throws {
        let contract = try Self.contract()
        #expect(contract.attributes.key.hasPrefix("alert:"))
        #expect(contract.attributes.line == "Central")
        #expect(contract.attributes.follow?.from.id == "940GZZLURBG")
        #expect(contract.attributes.follow?.mode == "tube")
        #expect(contract.state.trains.count == 3)
        #expect(contract.state.trains[1].late == 2)
        #expect(contract.state.trains[2].cancelled)
        #expect(contract.state.notice == "Severe delays")
        let trouble = try #require(contract.state.trouble)
        #expect(trouble.severity == "delays")
        #expect(trouble.from == "Leytonstone" && trouble.to == "Liverpool Street")
        #expect(trouble.cause == "Signal failure at Leytonstone")
        #expect(trouble.stretch == 0.29...1)
        #expect(contract.state.trains[0].date == Date(timeIntervalSince1970: 1795634274))
    }

    /// An older server says the notice alone; a stretch that isn't one is the whole ride.
    @Test func troubleIsOptionalAndBounded() throws {
        let plain = try JSONDecoder().decode(NextTrainAttributes.ContentState.self, from: Data(#"{"trains":[],"notice":"Severe delays","updated":1,"live":true}"#.utf8))
        #expect(plain.trouble == nil && plain.notice == "Severe delays")
        typealias Trouble = NextTrainAttributes.ContentState.Trouble
        #expect(Trouble(severity: "delays").stretch == 0...1)
        #expect(Trouble(severity: "delays", span: [0.8, 0.2]).stretch == 0.2...0.8)
        #expect(Trouble(severity: "delays", span: [-3, 7]).stretch == 0...1)
        #expect(Trouble(severity: "delays", span: [0.5]).stretch == 0...1)
        #expect(Trouble(severity: "delays", span: [.nan, 1]).stretch == 0...1)
        #expect(Trouble(severity: "delays").word(for: "Severe delays") == "Severe")
        #expect(Trouble(severity: "minor").word(for: "Minor delays") == "Minor")
        #expect(Trouble(severity: "closed").word(for: "Part suspended") == "Closed")
        #expect(Trouble(severity: "delays").word(for: "Reduced service") == "Delays")
    }

    /// What the app sends the server to follow is the follow it decodes.
    @Test func theFollowGoesBackAsItCame() throws {
        let follow = try #require(try Self.contract().attributes.follow)
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(follow)) as? NSDictionary
        #expect(sent?["mode"] as? String == "tube")
        #expect((sent?["to"] as? NSDictionary)?["name"] as? String == "Liverpool Street")
    }

    @Test func showsTheTrainsStillToLeave() throws {
        let state = try Self.contract().state
        let first = state.trains[0].date
        #expect(state.upcoming(at: first.addingTimeInterval(-60)).count == 3)
        #expect(state.upcoming(at: first.addingTimeInterval(10)).count == 3, "one leaving this moment still counts")
        #expect(state.upcoming(at: first.addingTimeInterval(60)).map(\.at) == Array(state.trains.dropFirst().map(\.at)))
        #expect(state.staleDate(after: first.addingTimeInterval(-60)) == first.addingTimeInterval(30))
        #expect(state.staleDate(after: first.addingTimeInterval(-3600)) == first.addingTimeInterval(-3600 + 15 * 60), "never more than a quarter of an hour")
    }

    @Test func aBoardBecomesTheNextTrains() {
        let now = Date(timeIntervalSince1970: 1_795_634_000)
        func departure(_ minutes: Double, late: Double = 0, cancelled: Bool = false, live: Bool = false) -> Departure {
            let scheduled = now.addingTimeInterval(minutes * 60)
            return Departure(id: "\(minutes)", line: "Central", mode: .tube, lineColor: nil, headsign: "Ealing Broadway", stopName: "Redbridge",
                             stopCoordinate: Coordinate(latitude: 51.576, longitude: 0.045), scheduled: scheduled,
                             expected: scheduled.addingTimeInterval(late * 60), isRealtime: live, isCancelled: cancelled)
        }
        let state = NextTrains.state([departure(9, late: 3, live: true), departure(-2), departure(4), departure(6, cancelled: true),
                                      departure(15), departure(20)], live: false, now: now)
        #expect(state.trains.map { ($0.at - now.timeIntervalSince1970) / 60 } == [4, 6, 12, 15])
        #expect(state.trains[1].cancelled)
        #expect(state.trains[2].late == 3)
        #expect(state.live, "a live time among them")
        #expect(state.updated == now.timeIntervalSince1970)
    }

    @Test func savedLinesSayWhetherTheyCanStartOne() throws {
        var alert = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "central", name: "Central line"), mode: "tube",
                                                             from: .init(id: "940GZZLURBG", name: "Redbridge"),
                                                             to: .init(id: "940GZZLULVT", name: "Liverpool Street"))])
        #expect(alert.canStartLiveActivity)
        alert.segments[0].mode = "national-rail"
        #expect(!alert.canStartLiveActivity)
        alert.segments[0] = RouteAlert.Segment(line: .init(id: "central", name: "Central line"), mode: "tube")
        #expect(!alert.canStartLiveActivity, "a whole line has nowhere to board")

        // The server boards the first stretch going out and the last coming back: a National Rail
        // leg first only counts at a time going back.
        let tube = RouteAlert.Segment(line: .init(id: "central", name: "Central line"), mode: "tube",
                                      from: .init(id: "940GZZLURBG", name: "Redbridge"), to: .init(id: "940GZZLULVT", name: "Liverpool Street"))
        let rail = RouteAlert.Segment(line: .init(id: "c2c", name: "c2c"), mode: "national-rail",
                                      from: .init(id: "910GFENCHRS", name: "Fenchurch Street"), to: .init(id: "910GUPMNSTR", name: "Upminster"))
        var mixed = RouteAlert(segments: [rail, tube])
        mixed.windows = [RouteAlert.TimeWindow(start: 7 * 60, end: 9 * 60)]
        #expect(!mixed.canStartLiveActivity)
        mixed.windows[0].direction = .back
        #expect(mixed.canStartLiveActivity)

        // Sent only when on, so alerts without it go to the server as before.
        alert.liveActivity = true
        let on = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RouteAlert.Wire(alert: alert))) as? NSDictionary
        #expect(on?["liveActivity"] as? Bool == true)
        alert.liveActivity = nil
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RouteAlert.Wire(alert: alert))) as? NSDictionary
        #expect(off?["liveActivity"] == nil)
    }
}
