import Foundation
import Testing
@testable import Beeline

/// Departure boards against stop times recorded at King's Cross St. Pancras
/// (Underground, 18:04 to 18:39 on 31 Oct 2026; each trip's stops trimmed to the next eight).
struct DepartureTests {
    static let kingsCross = Coordinate(latitude: 51.5306, longitude: -0.1240)
    static let bank = Coordinate(latitude: 51.5133, longitude: -0.0886)

    /// The Northern line leg a journey planner gave: King's Cross to Bank at 18:08.
    static func northernLeg(departing: String = "2026-10-31T18:08:00Z") -> Leg {
        let departure = Time.iso(departing)!
        return Leg(mode: .tube, line: "Northern", headsign: "Morden", fromName: "King's Cross St. Pancras", toName: "Bank",
                   departure: departure, arrival: departure.addingTimeInterval(9 * 60), path: [kingsCross, bank])
    }

    static func board(_ leg: Leg = northernLeg()) throws -> DepartureBoard {
        try DepartureProvider.parseBoard(ProviderParsingTests.fixture("transitous-departures"), for: leg)
    }

    @Test func keepsOnlyWhatStopsWhereYouGetOff() throws {
        let board = try Self.board()
        #expect(!board.departures.isEmpty)
        // Edgware, High Barnet and Mill Hill East trains go north; Victoria trains never reach Bank.
        #expect(board.departures.allSatisfy { $0.arrivalThere != nil })
        #expect(!board.departures.contains { $0.headsign == "Edgware" || $0.line == "Victoria" })
        #expect(board.departures.map(\.expected) == board.departures.map(\.expected).sorted())
        #expect(board.stopName == "King's Cross St. Pancras")
    }

    @Test func findsThePlannedTrainAndWhatMissingItCosts() throws {
        let board = try Self.board()
        let planned = try #require(board.planned)
        #expect(planned.scheduled == Time.iso("2026-10-31T18:08:00Z"))
        #expect(planned.arrivalThere == Time.iso("2026-10-31T18:17:00Z"))
        #expect(planned.platform != nil)

        let next = try #require(board.nextAfterPlanned)
        #expect(next.scheduled == Time.iso("2026-10-31T18:11:00Z"))
        #expect(abs((board.arrivalDifference(next) ?? 0) - 180) < 1)

        let earlier = try #require(board.earlierThanPlanned(after: Time.iso("2026-10-31T18:00:00Z")!))
        #expect(earlier.scheduled == Time.iso("2026-10-31T18:05:00Z"))
        #expect(abs((board.arrivalDifference(earlier) ?? 0) + 180) < 1)
        // Once the 18:05 has gone, there's nothing earlier to run for.
        #expect(board.earlierThanPlanned(after: Time.iso("2026-10-31T18:06:00Z")!) == nil)
    }

    @Test func carriesTheLinesStatus() throws {
        #expect(try Self.board().alerts.contains { $0.header == "Minor Delays" })
        // A stop's alerts cover every line through it; only this line's (and plain station notices) stay.
        let northern = DepartureProvider.Response.Alert(headerText: "Minor Delays", descriptionText: "Northern Line: Minor delays due to train cancellations.")
        let station = DepartureProvider.Response.Alert(headerText: "Lifts", descriptionText: "No step-free access at this station until Sunday.")
        #expect(DepartureProvider.concerns(northern, line: "Northern"))
        #expect(!DepartureProvider.concerns(northern, line: "Metropolitan"))
        #expect(DepartureProvider.concerns(station, line: "Metropolitan"))
    }

    @Test func plansNothingWhenNoTrainLeavesThen() throws {
        // A source's time three minutes adrift of any timetabled train.
        let board = try Self.board(Self.northernLeg(departing: "2026-10-31T18:09:30Z"))
        #expect(board.planned?.scheduled == Time.iso("2026-10-31T18:08:00Z") || board.planned?.scheduled == Time.iso("2026-10-31T18:11:00Z"))
        let adrift = try Self.board(Self.northernLeg(departing: "2026-10-31T19:30:00Z"))
        #expect(adrift.planned == nil)
    }

    @Test func boardRequestNarrowsToTheRightKindOfVehicle() throws {
        let request = try #require(DepartureProvider.boardRequest(for: Self.northernLeg()))
        let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(value("mode") == "SUBWAY")
        #expect(value("fetchStops") == "true")
        #expect(value("center") == Self.kingsCross.pair)
        // Twenty minutes before the planned departure, so the ones just missed show too.
        #expect(value("time") == Time.isoString(Time.iso("2026-10-31T17:48:00Z")!))
    }

    @Test func aCachedNearbyBoardDropsDepartedTrainsAsTimePasses() throws {
        let lines = try DepartureProvider.parseNearby(ProviderParsingTests.fixture("transitous-nearby"),
                                                      around: Self.kingsCross, now: Time.iso("2026-10-31T18:19:00Z")!)
        let line = try #require(lines.first { $0.departures.count >= 2 && $0.departures.first?.expected != $0.departures.last?.expected })
        let first = try #require(line.departures.first).expected
        let last = try #require(line.departures.last).expected
        let upcoming = try #require(line.upcoming(at: first.addingTimeInterval(1)))
        #expect(upcoming.departures.allSatisfy { $0.expected > first })
        #expect(line.upcoming(at: last.addingTimeInterval(1)) == nil)
    }

    @Test func nearbyGroupsByLineAndDirectionFromTheNearestStop() throws {
        let here = Coordinate(latitude: 51.5308, longitude: -0.1238)
        let lines = try DepartureProvider.parseNearby(ProviderParsingTests.fixture("transitous-nearby"),
                                                      around: here, now: Time.iso("2026-10-31T18:19:00Z")!)
        #expect(!lines.isEmpty)
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(lines.allSatisfy { !$0.departures.isEmpty && $0.departures.count <= 3 && $0.distance < 450 })
        #expect(lines.allSatisfy { line in line.departures.allSatisfy { $0.stopName == line.stopName } })
        #expect(lines.contains { $0.mode == .tube && $0.line == "Northern" })
        #expect(lines.contains { $0.mode == .bus })
        // Nearest first, in 100 m bands.
        #expect(lines.map { Int($0.distance / 100) } == lines.map { Int($0.distance / 100) }.sorted())
    }
}

@Suite struct PlatformWordingTests {
    @Test func aBusStandsAtAStopAndATrainAtAPlatform() {
        let at = Date(timeIntervalSince1970: 0)
        let bus = Leg(mode: .bus, line: "277", fromName: "Canary Wharf", toName: "Limehouse", departure: at, arrival: at)
        let tube = Leg(mode: .tube, line: "Jubilee", fromName: "Bond Street", toName: "Canary Wharf", departure: at, arrival: at)
        #expect(bus.standing(at: "G") == "stop\u{00A0}G")
        #expect(tube.standing(at: "4") == "platform\u{00A0}4")
    }
}
