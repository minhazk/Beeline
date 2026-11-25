#if DEBUG
import ActivityKit
import Foundation

/// Launch with `-demo` to plan King's Cross → Canary Wharf straight away (add
/// `-demoDetail` to open the best journey, `-demoGo` to start it too), for
/// checking screens without tapping.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")
    static let opensDetail = ProcessInfo.processInfo.arguments.contains("-demoDetail") || startsTrip
    static let startsTrip = ProcessInfo.processInfo.arguments.contains("-demoGo")
    /// `-demoLeg 2` starts Go at that step (0-based), for shooting a ride, a change or the last leg.
    static let startLeg: Int? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoLeg"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }()
    /// `-demoHeading` points the phone north-east, for the beam on your dot.
    static let heading: Double? = ProcessInfo.processInfo.arguments.contains("-demoHeading") ? 50 : nil
    /// `-demoNotices` adds two more TfL notices to every search, for the busiest routes page.
    static let addsNotices = ProcessInfo.processInfo.arguments.contains("-demoNotices")
    static let notices = [
        ServiceNotice(title: "Severe delays on the Elizabeth line", detail: "Severe delays between Paddington and Abbey Wood while we fix a signal failure.",
                      severity: .delays, source: .tfl, leg: UUID()),
        ServiceNotice(title: "Canary Wharf part closed (Jubilee line)", detail: "The westbound platform is closed. Use the eastbound platform and change at North Greenwich.",
                      severity: .closed, source: .tfl, leg: UUID()),
    ]
    /// `-demoReplan offer|wait|early`: opens Go on a canned trip, early onto the Bakerloo, with
    /// canned boards and a canned planner answer and no network at all (`ReplanDemo`).
    static let replan: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoReplan"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    /// No searches, boards, nearby departures or buses: the canned trip carries its own boards.
    static var offline: Bool { replan != nil }
    static let origin = JourneyQuery.londonExample.origin
    static let destination = JourneyQuery.londonExample.destination

    /// `-demoNextTrain`: the next Central line trains from Redbridge on the Lock Screen, canned
    /// (one late, one cancelled, trouble on the line), without the alerts server.
    static let showsNextTrain = ProcessInfo.processInfo.arguments.contains("-demoNextTrain")

    @MainActor static func startNextTrain(now: Date = .now) async {
        func departure(_ minutes: Double, late: Double = 0, cancelled: Bool = false) -> Departure {
            let scheduled = now.addingTimeInterval(minutes * 60)
            return Departure(id: "demo-\(minutes)", line: "Central", mode: .tube, lineColor: LineColors.color(line: "Central", mode: .tube),
                             headsign: "Ealing Broadway", stopName: "Redbridge", stopCoordinate: Coordinate(latitude: 51.5763, longitude: 0.0454),
                             scheduled: scheduled, expected: scheduled.addingTimeInterval(late * 60), isRealtime: true, isCancelled: cancelled)
        }
        let departures = [departure(4.9), departure(6.9, late: 2), departure(13.9, cancelled: true), departure(17.9)]
        NextTrains.shared.start(NextTrains.Request(key: "demo", line: "Central", mode: .tube, color: departures[0].lineColor, stop: "Redbridge",
                                                   towards: "Liverpool Street", follow: nil, departures: departures, refresh: nil))
        var state = NextTrains.state(departures, live: true, now: now)
        state.notice = "Severe delays"
        for activity in Activity<NextTrainAttributes>.activities {
            nonisolated(unsafe) let activity = activity
            await activity.update(ActivityContent(state: state, staleDate: state.staleDate(after: now)))
        }
    }
}
#endif
