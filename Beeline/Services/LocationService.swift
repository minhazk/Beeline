import CoreLocation
import Observation

@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Coordinate, any Error>] = []
    private(set) var last: Coordinate?
    private(set) var authorization: CLAuthorizationStatus

    /// Continuous fixes while a trip is live, with speed and accuracy.
    private(set) var live: CLLocation?
    /// Which way the phone points, while the app is open.
    private(set) var heading: Heading?

    struct Heading: Equatable {
        /// From true north where known, else magnetic.
        var degrees: Double
        /// Give or take, in degrees.
        var accuracy: Double
    }
    private var liveTask: Task<Void, Never>?
    /// Keeps fixes coming with the screen locked (the blue pill in the status bar).
    private var backgroundSession: CLBackgroundActivitySession?

    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isTracking: Bool { liveTask != nil }

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.headingFilter = 3
        #if DEBUG
        // The simulator has no compass.
        if let degrees = Demo.heading { heading = Heading(degrees: degrees, accuracy: 20) }
        #endif
    }

    /// The compass, for the beam on your dot; only while the app is in front.
    func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        manager.stopUpdatingHeading()
    }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// A fresh fix, or the last one if it's under 20 seconds old.
    func current() async throws -> Coordinate {
        if let live, live.timestamp.timeIntervalSinceNow > -20 { return Coordinate(live.coordinate) }
        if let location = manager.location, location.timestamp.timeIntervalSinceNow > -20 {
            return Coordinate(location.coordinate)
        }
        requestPermission()
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    func startTracking() {
        guard liveTask == nil else { return }
        requestPermission()
        backgroundSession = CLBackgroundActivitySession()
        liveTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 {
                        self.live = location
                        self.last = Coordinate(location.coordinate)
                    }
                }
            } catch {
                // Updates end with the task; nothing to recover.
            }
        }
    }

    func stopTracking() {
        liveTask?.cancel()
        liveTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        MainActor.assumeIsolated {
            last = Coordinate(coordinate)
            waiting.forEach { $0.resume(returning: Coordinate(coordinate)) }
            waiting = []
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Negative accuracy means the compass can't tell (it needs calibrating, or there's interference).
        let reading = newHeading.headingAccuracy < 0 ? nil
            : Heading(degrees: newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading,
                      accuracy: newHeading.headingAccuracy)
        MainActor.assumeIsolated { heading = reading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            waiting.forEach { $0.resume(throwing: error) }
            waiting = []
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.requestLocation() }
        }
    }
}
