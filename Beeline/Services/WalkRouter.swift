import MapKit

/// Walking directions from MapKit: turn-by-turn steps the transit sources don't give.
enum WalkRouter {
    @MainActor
    static func route(from: Coordinate, to: Coordinate) async throws -> WalkRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = .walking
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw ProviderError.noRoutes }
        return WalkRoute(
            path: coordinates(route.polyline),
            steps: route.steps.map { WalkRoute.Step(instruction: $0.instructions, distance: $0.distance) },
            distance: route.distance,
            expectedTime: route.expectedTravelTime)
    }

    /// How long walking it would take, without the route itself.
    @MainActor
    static func walkingTime(from: Coordinate, to: Coordinate) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = .walking
        return try await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    /// A source's own walking path when MapKit can't help (no signal, too far).
    static func fallback(for leg: Leg) -> WalkRoute? {
        guard leg.path.count > 1 else { return nil }
        let distance = leg.distanceMeters ?? PathProgress.length(of: leg.path)
        return WalkRoute(path: leg.path, steps: [], distance: distance, expectedTime: leg.duration)
    }

    private static func coordinates(_ polyline: MKPolyline) -> [Coordinate] {
        var points = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.map(Coordinate.init)
    }
}
