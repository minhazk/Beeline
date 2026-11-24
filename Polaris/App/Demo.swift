#if DEBUG
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
}
#endif
