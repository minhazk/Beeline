import CoreLocation
import Foundation

struct Coordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var clLocation: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    /// "lat,lon", the form every provider and deep link takes.
    var pair: String { "\(latitude),\(longitude)" }

    /// Metres to another point, along the ground.
    func distance(to other: Coordinate) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

extension Coordinate {
    init(_ c: CLLocationCoordinate2D) { self.init(latitude: c.latitude, longitude: c.longitude) }
}

struct Place: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var subtitle: String?
    var coordinate: Coordinate
    /// Resolved from GPS at search time rather than picked from search.
    var isCurrentLocation = false

    static func currentLocation(_ coordinate: Coordinate) -> Place {
        Place(name: "Current Location", coordinate: coordinate, isCurrentLocation: true)
    }
}

enum TimeMode: Codable, Hashable, Sendable {
    case leaveNow
    case departAt(Date)
    case arriveBy(Date)

    var date: Date {
        switch self {
        case .leaveNow: .now
        case .departAt(let d), .arriveBy(let d): d
        }
    }

    var isArriveBy: Bool {
        if case .arriveBy = self { true } else { false }
    }
}

struct JourneyQuery: Codable, Hashable, Sendable {
    var origin: Place
    var destination: Place
    var time: TimeMode

    static let londonExample = JourneyQuery(
        origin: Place(name: "King's Cross", coordinate: .init(latitude: 51.5308, longitude: -0.1238)),
        destination: Place(name: "Canary Wharf", coordinate: .init(latitude: 51.5035, longitude: -0.0187)),
        time: .leaveNow)
}
