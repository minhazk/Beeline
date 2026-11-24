import Foundation
import Testing
@testable import Beeline

/// Alerts for your lines: the stations along a line, picking the stretch you ride,
/// and the JSON the alerts server takes (the same contract file its tests read).
@MainActor
struct AlertTests {
    static func elizabeth() throws -> TfLLines.Route {
        try TfLLines.parseRoute(ProviderParsingTests.fixture("tfl-route-elizabeth"))
    }

    @Test func oneStationHasEveryIdTfLUsesForIt() throws {
        let route = try Self.elizabeth()
        let liverpool = try #require(route.station(named: "Liverpool Street"))
        #expect(liverpool.name == "Liverpool Street")
        #expect(liverpool.ids.first == "910GLIVSTLL")
        #expect(Set(liverpool.ids) == ["910GLIVSTLL", "910GLIVST"])
        // Other sources' spellings find it too.
        #expect(route.station(named: "London Liverpool Street")?.id == liverpool.id)
        #expect(route.station(named: "Liverpool Street Rail Station")?.id == liverpool.id)
        #expect(route.stations.filter { $0.name == "Paddington" }.count == 1)
        #expect(route.stations.count > 35)
    }

    @Test func theStretchYouRideAlongTheLine() throws {
        let route = try Self.elizabeth()
        let station = { (name: String) in try #require(route.station(named: name)) }
        let run = try #require(route.stretch(from: try station("Liverpool Street"), to: try station("Canary Wharf")))
        #expect(run.map(\.name) == ["Liverpool Street", "Whitechapel", "Canary Wharf"])
        // Either direction, and across the central section onto a branch.
        let west = try #require(route.stretch(from: try station("Canary Wharf"), to: try station("Paddington")))
        #expect(west.map(\.name) == ["Canary Wharf", "Whitechapel", "Liverpool Street", "Farringdon", "Tottenham Court Road", "Bond Street", "Paddington"])
        let segment = route.segment(TfLLines.Line(id: "elizabeth", tflName: "Elizabeth line", mode: "elizabeth-line"),
                                    from: try station("Liverpool Street"), to: try station("Canary Wharf"))
        #expect(segment.stations == ["910GLIVSTLL|910GLIVST", "910GWCHAPXR", "910GCANWHRF"])
        #expect(segment.stretch == "Liverpool Street to Canary Wharf")
    }

    @Test func linesAsPeopleSayThem() throws {
        let lines = try TfLLines.parseLines(ProviderParsingTests.fixture("tfl-lines"))
        let name = { (id: String) in lines.first { $0.id == id }?.name }
        #expect(name("district") == "District line")
        #expect(name("elizabeth") == "Elizabeth line")
        #expect(name("mildmay") == "Mildmay line")
        #expect(name("dlr") == "DLR")
        #expect(name("southeastern") == "Southeastern")
        #expect(lines.first { $0.id == "mildmay" }?.legMode == .overground)
    }

    @Test func otherSourcesRidesFindTheirTfLLine() throws {
        let lines = try TfLLines.parseLines(ProviderParsingTests.fixture("tfl-lines"))
        let ride = { (mode: LegMode, line: String?) in
            TfLLines.line(for: Leg(mode: mode, line: line, fromName: "A", toName: "B", departure: .now, arrival: .now), in: lines)?.id
        }
        #expect(ride(.rail, "Elizabeth line") == "elizabeth")
        #expect(ride(.tube, "Central") == "central")
        #expect(ride(.tube, "Hammersmith & City") == "hammersmith-city")
        #expect(ride(.rail, "Mildmay") == "mildmay")
        #expect(ride(.dlr, nil) == "dlr")
        #expect(ride(.bus, "25") == nil)
    }

    @Test func sendsWhatTheServerExpects() throws {
        struct Contract: Decodable { var environment: String; var timeZone: String; var alerts: [RouteAlert] }
        let data = try ProviderParsingTests.fixture("alert-contract")
        let contract = try JSONDecoder().decode(Contract.self, from: data)
        #expect(contract.alerts[0].segments[0].from?.name == "Liverpool Street")
        #expect(contract.alerts[1].segments[0].from == nil)
        #expect(contract.alerts[0].direction == .out)
        // As older builds sent it: no direction, and none is added on the way back out.
        #expect(contract.alerts[1].direction == nil)
        // A time with its own way, and one following the alert's.
        #expect(contract.alerts[0].windows.map(\.direction) == [nil, .back])
        #expect(contract.alerts[0].windows.map(contract.alerts[0].way(of:)) == [.out, .back])

        let sent = try JSONEncoder().encode(RouteAlert.Registration(environment: contract.environment, timeZone: contract.timeZone,
                                                                     alerts: contract.alerts.map(RouteAlert.Wire.init)))
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let resent = try JSONSerialization.jsonObject(with: sent) as? NSDictionary
        #expect(original == resent)
    }

    /// Alerts are kept as JSON in UserDefaults and a failed decode loses them all, so alerts saved
    /// before directions (and a direction a newer build wrote) must still load.
    @Test func alertsSavedBeforeDirectionsStillLoad() throws {
        let stored = #"[{"id":"A","name":"","days":[1,2,3,4,5],"windows":[{"start":420,"end":600}],"minorDelays":true,"segments":[{"line":{"id":"elizabeth","name":"Elizabeth line"},"mode":"elizabeth-line","from":{"id":"910GLIVSTLL|910GLIVST","name":"Liverpool Street"},"to":{"id":"910GCANWHRF","name":"Canary Wharf"},"stations":["910GLIVSTLL|910GLIVST","910GWCHAPXR","910GCANWHRF"]}]},"#
            + #"{"id":"B","name":"","days":[6],"windows":[{"start":600,"end":840}],"minorDelays":false,"segments":[],"direction":"sideways"}]"#
        let alerts = try JSONDecoder().decode([RouteAlert].self, from: Data(stored.utf8))
        #expect(alerts.count == 2)
        #expect(alerts[0].direction == nil)
        #expect(alerts[0].way == .both)
        #expect(alerts[1].direction == .both)
        // Saved again, the old one still has no direction.
        let resaved = try JSONSerialization.jsonObject(with: JSONEncoder().encode([alerts[0]])) as? [[String: Any]]
        #expect(resaved?[0]["direction"] == nil)

        var back = alerts[0]
        back.way = .back
        let decoded = try JSONDecoder().decode(RouteAlert.self, from: JSONEncoder().encode(back))
        #expect(decoded.direction == .back)
    }

    @Test func whichWayInTheEditor() throws {
        var alert = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "elizabeth", name: "Elizabeth line"), mode: "elizabeth-line",
                                                             from: .init(id: "a", name: "Liverpool Street"), to: .init(id: "b", name: "Canary Wharf"))])
        // A new alert is both ways, as the editor shows it.
        #expect(alert.direction == nil)
        #expect(alert.way == .both)
        #expect(RouteAlert.Direction.allCases.map(alert.label) == ["To Canary Wharf", "To Liverpool Street", "Both ways"])
        alert.way = .back
        #expect(alert.displayName == "Canary Wharf → Liverpool Street")
        alert.way = .out
        #expect(alert.displayName == "Liverpool Street → Canary Wharf")
        // Whole lines have no ends, so no choice.
        let whole = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "district", name: "District line"), mode: "tube")])
        #expect(whole.ends == nil)
    }

    /// Alerts saved before times had ways, and a way a newer build wrote, still load.
    @Test func timesWithTheirOwnWay() throws {
        let stored = #"{"id":"A","name":"","days":[1,2,3,4,5],"windows":[{"start":420,"end":600},{"start":990,"end":1170,"direction":"back"},{"start":1200,"end":1260,"direction":"sideways"}],"minorDelays":true,"direction":"out","segments":[{"line":{"id":"elizabeth","name":"Elizabeth line"},"mode":"elizabeth-line","from":{"id":"a","name":"Liverpool Street"},"to":{"id":"b","name":"Canary Wharf"},"stations":["a","b"]}]}"#
        var alert = try JSONDecoder().decode(RouteAlert.self, from: Data(stored.utf8))
        #expect(alert.windows.map(\.direction) == [nil, .back, .both])
        #expect(alert.waysDiffer)
        #expect(alert.displayName == "Liverpool Street ⇄ Canary Wharf")
        // Three in a list: the comma before "and" is the locale's.
        #expect(alert.whenText.hasPrefix("Weekdays, 07:00–10:00 to Canary Wharf, 16:30–19:30 to Liverpool Street"))
        #expect(alert.whenText.hasSuffix(" and 20:00–21:00 both ways"))
        // Saved again, a time following the alert writes no way.
        let resaved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(alert)) as? [String: Any]
        let windows = resaved?["windows"] as? [[String: Any]]
        #expect(windows?[0]["direction"] == nil)
        #expect(windows?[1]["direction"] as? String == "back")

        // Times all going the same way: names and times as before.
        alert.windows = [.init(start: 420, end: 600), .init(start: 990, end: 1170, direction: .out)]
        #expect(!alert.waysDiffer)
        #expect(alert.displayName == "Liverpool Street → Canary Wharf")
        #expect(alert.whenText == "Weekdays, 07:00–10:00 and 16:30–19:30")

        // Whole lines have no ends: no ways to tell apart.
        var whole = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "district", name: "District line"), mode: "tube")])
        whole.windows[1].direction = .back
        #expect(!whole.waysDiffer)
        #expect(whole.whenText == "Weekdays, 07:00–10:00 and 16:30–19:30")
    }

    /// Review 4: a time's way set on purpose stays as set, even when it matches Which way then.
    @Test func aTimesOwnWayStaysWhenWhichWayChanges() throws {
        var alert = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "elizabeth", name: "Elizabeth line"), mode: "elizabeth-line",
                                                             from: .init(id: "a", name: "Reading"), to: .init(id: "b", name: "Paddington"))])
        alert.windows[1].direction = .both
        // Saved as set (the editor stores the alert as it is), then Which way changes.
        var saved = try JSONDecoder().decode(RouteAlert.self, from: JSONEncoder().encode(alert))
        #expect(saved.windows[1].direction == .both)
        saved.way = .out
        #expect(saved.way(of: saved.windows[1]) == .both)
        // A time's own way that matches Which way reads as no difference.
        saved.windows[0].direction = .out
        #expect(saved.whenText == "Weekdays, 07:00–10:00 to Paddington and 16:30–19:30 both ways")
        saved.windows[1].direction = .out
        #expect(!saved.waysDiffer)
        #expect(saved.displayName == "Reading → Paddington")
        #expect(saved.whenText == "Weekdays, 07:00–10:00 and 16:30–19:30")
    }

    @Test func namesAndTimesForTheList() throws {
        var alert = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "elizabeth", name: "Elizabeth line"), mode: "elizabeth-line",
                                                             from: .init(id: "a", name: "Liverpool Street"), to: .init(id: "b", name: "Canary Wharf"))])
        #expect(alert.displayName == "Liverpool Street → Canary Wharf")
        #expect(alert.whenText == "Weekdays, 07:00–10:00 and 16:30–19:30")
        alert.name = "Work"
        #expect(alert.displayName == "Work")
        alert.days = [6, 7]
        alert.windows = [.init(start: 600, end: 840)]
        #expect(alert.whenText == "Weekends, 10:00–14:00")
        let whole = RouteAlert(segments: [RouteAlert.Segment(line: .init(id: "district", name: "District line"), mode: "tube")])
        #expect(whole.displayName == "District line")
        #expect(whole.segments[0].stretch == "Whole line")
        #expect(whole.segments[0].legMode == .tube)
    }

    @Test func readsTheServersStatus() throws {
        let json = #"{"checkedAt":"2026-11-09T11:29:56.589Z","alerts":[{"id":"x","issues":[{"severity":"closed","title":"Canary Wharf closed (Elizabeth line)","detail":"Closed"}],"upcoming":[{"severity":"closed","title":"Elizabeth line: part closure","detail":"Sunday","from":"2026-11-15T04:30:00.000Z"}]}]}"#
        let status = try AlertStatus.decode(Data(json.utf8))
        #expect(status.alerts[0].issues[0].level == .closed)
        #expect(status.alerts[0].upcoming[0].from == Time.iso("2026-11-15T04:30:00Z"))
    }
}
