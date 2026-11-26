import Foundation
import Testing
@testable import Beeline

struct LondonStrikeTests {
    private let month = """
    <h2>Tube drivers’ strikes</h2><h2>Strike dates</h2>
    <h3>June 2027</h3><ul><li>12:00 Thursday 17 to 11:59 Friday 18 June 2027</li></ul>
    <h2>Likely impact</h2><ul><li>No service after 21:00.</li></ul>
    """

    @Test func publishedDatesUseLondonTimeAndSurviveCMSDelivery() throws {
        let encoded = try JSONSerialization.data(withJSONObject: [1, month])
        for html in [month, "<script>self.__next_f.push(" + String(decoding: encoded, as: UTF8.self) + ")</script>"] {
            let reading = try #require(StrikeCalendar.parse(html))
            #expect(reading.complete)
            #expect(reading.events.count == 1)
            #expect(reading.events.first?.start == Time.iso("2027-06-17T11:00:00Z"))
            #expect(reading.events.first?.end == Time.iso("2027-06-18T10:59:00Z"))
        }
        #expect(StrikeCalendar.parse("<main>Loading</main>") == nil)
        let changed = month.replacingOccurrences(of: "12:00 Thursday 17 to 11:59 Friday 18 June 2027", with: "New timetable to follow")
        #expect(StrikeCalendar.parse(changed)?.complete == false)
    }

    @Test func withdrawalAfterTheDatesRemovesThePublishedPeriod() throws {
        let withdrawn = month.replacingOccurrences(of: "<h2>Likely impact</h2>", with: "<p>The strikes have been called off.</p><h2>Likely impact</h2>")
        let result = try #require(StrikeCalendar.parse(withdrawn))
        #expect(result.events.isEmpty)
        #expect(result.complete)
    }

    @Test func selectiveWithdrawalsAndServiceSuspensionsKeepTheOtherDates() throws {
        let heading = "<h2>Bus drivers’ strikes</h2><h2>Strike dates</h2>"
        let dates = "<li>12:00 Thursday 17 to 11:59 Friday 18 June 2027</li><li>12:00 Saturday 19 to 11:59 Sunday 20 June 2027</li>"
        let impact = "<p>During the strikes, services may be suspended.</p>"
        #expect(StrikeCalendar.parse(heading + dates + impact)?.events.count == 2)
        let withdrawal = "<p>The strike on 17 June has been called off.</p>"
        for html in [dates + withdrawal, withdrawal + dates] {
            let events = try #require(StrikeCalendar.parse(heading + html)).events
            #expect(events.count == 1)
            #expect(events.first?.start == Time.iso("2027-06-19T11:00:00Z"))
        }
    }

    @Test func matchesBusCalendarAndLineNoticesByOperator() throws {
        let published = try #require(StrikeCalendar.parse(month.replacingOccurrences(of: "Tube drivers", with: "Metroline bus drivers"))).events
        let lines = ["Metroline", "Arriva"].enumerated().map { index, company in
            LondonStrikes.Line(id: String(index), name: String(index), modeName: "bus", lineStatuses: [
                .init(statusSeverityDescription: "Information", reason: company + " bus drivers’ strike.", validityPeriods: [
                    .init(fromDate: "2027-06-17T11:00:00Z", toDate: "2027-06-18T10:59:00Z")
                ], disruption: nil)
            ])
        }
        for date in ["2027-06-16T12:00:00Z", "2027-06-17T12:00:00Z"] {
            let now = try #require(Time.iso(date))
            let board = LondonStrikes.board(current: lines, forecast: [], calendar: published, now: now, warnings: [])
            #expect(board.events.count == 2)
            #expect(board.events.first(where: \.publishedDate)?.lines == ["Route 0"])
        }
    }

    @Test func mergesCalendarWithTubeImpactsAndKeepsOtherDisputes() throws {
        let published = try #require(StrikeCalendar.parse(month)).events
        let now = try #require(Time.iso("2027-06-17T13:45:00Z"))
        func line(_ id: String, _ mode: String, _ text: String) -> LondonStrikes.Line {
            .init(id: id, name: id.capitalized, modeName: mode, lineStatuses: [
                .init(statusSeverityDescription: "Information", reason: text, validityPeriods: [], disruption: nil)
            ])
        }
        let current = [line("victoria", "tube", "Strike action has reduced train service."),
                       line("circle", "tube", "No service due to strike action."),
                       line("10", "bus", "North depot strike action."), line("25", "bus", "East depot strike action."),
                       line("90", "bus", "Bridge strike."), line("95", "bus", "A strike has been called off.")]
        let result = LondonStrikes.board(current: current, forecast: [], calendar: published, now: now, warnings: [])
        #expect(result.events.count == 3)
        let tube = try #require(result.events.first { $0.isTube })
        #expect(tube.lines == ["Victoria", "Circle"])
        #expect(tube.details.count == 2)
        #expect(tube.publishedDate)
        let later = LondonStrikes.board(current: [], forecast: [], calendar: published, now: now.addingTimeInterval(2 * 86_400), warnings: [])
        #expect(later.events.isEmpty)
    }
}
