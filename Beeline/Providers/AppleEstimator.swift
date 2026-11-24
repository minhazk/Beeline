import MapKit

/// MapKit answers `.transit` only with an ETA, never a route, so Apple gives a
/// reference time to compare the real journeys against.
enum AppleEstimator {
    @MainActor
    static func estimate(_ query: JourneyQuery) async throws -> AppleEstimate {
        let request = MKDirections.Request()
        request.source = mapItem(query.origin)
        request.destination = mapItem(query.destination)
        request.transportType = .transit
        switch query.time {
        case .leaveNow: break
        case .departAt(let date): request.departureDate = date
        case .arriveBy(let date): request.arrivalDate = date
        }
        let directions = MKDirections(request: request)
        return try await withCheckedThrowingContinuation { continuation in
            directions.calculateETA { response, error in
                if let response {
                    continuation.resume(returning: AppleEstimate(
                        travelTime: response.expectedTravelTime,
                        departure: response.expectedDepartureDate,
                        arrival: response.expectedArrivalDate))
                } else {
                    continuation.resume(throwing: error ?? ProviderError.noRoutes)
                }
            }
        }
    }

    /// From where you are to a place, for choosing between places.
    @MainActor
    static func travelTime(to item: MKMapItem) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = item
        request.transportType = .transit
        return try await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    @MainActor
    private static func mapItem(_ place: Place) -> MKMapItem {
        if place.isCurrentLocation { return .forCurrentLocation() }
        let item = MKMapItem(location: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude), address: nil)
        item.name = place.name
        return item
    }
}
