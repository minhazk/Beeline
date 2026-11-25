import UIKit

extension TimeMode {
    /// Public directions links open the endpoints. The receiving app controls its journey time.
    var handoffTimeReminder: String? {
        switch self {
        case .leaveNow: nil
        case .departAt(let date): "Set departure to \(date.formatted(date: .abbreviated, time: .shortened)) in the other app."
        case .arriveBy(let date): "Check the arrival time is \(date.formatted(date: .abbreviated, time: .shortened)) in the other app."
        }
    }
}

/// Hand the same trip to another app: the one-tap second opinion for apps
/// (Citymapper above all) that have no API to ask directly.
enum OpenIn: String, CaseIterable, Identifiable {
    case citymapper, googleMaps, appleMaps

    var id: String { rawValue }

    var name: String {
        switch self {
        case .citymapper: "Citymapper"
        case .googleMaps: "Google Maps"
        case .appleMaps: "Apple Maps"
        }
    }

    var symbol: String {
        switch self {
        case .citymapper: "arrow.triangle.turn.up.right.diamond.fill"
        case .googleMaps: "mappin.and.ellipse"
        case .appleMaps: "map.fill"
        }
    }

    @MainActor
    func open(_ query: JourneyQuery) {
        UIApplication.shared.open(url(query))
    }

    /// The publisher's own https link, which opens its app when installed and its site when not.
    /// Never the app's custom scheme ("citymapper:", "comgooglemaps:"): any app can claim one,
    /// and would be handed where you are going, and from where.
    func url(_ query: JourneyQuery) -> URL {
        let from = query.origin, to = query.destination
        switch self {
        case .citymapper:
            var items = [URLQueryItem(name: "endcoord", value: to.coordinate.pair), URLQueryItem(name: "endname", value: to.name)]
            if !from.isCurrentLocation {
                items += [URLQueryItem(name: "startcoord", value: from.coordinate.pair), URLQueryItem(name: "startname", value: from.name)]
            }
            if case .arriveBy(let date) = query.time {
                items.append(URLQueryItem(name: "arrival_time", value: Time.isoString(date)))
            }
            return url("https://citymapper.com/directions", items)
        case .googleMaps:
            var web = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "destination", value: to.coordinate.pair),
                       URLQueryItem(name: "travelmode", value: "transit")]
            if !from.isCurrentLocation { web.append(URLQueryItem(name: "origin", value: from.coordinate.pair)) }
            return url("https://www.google.com/maps/dir/", web)
        case .appleMaps:
            var items = [URLQueryItem(name: "daddr", value: to.coordinate.pair), URLQueryItem(name: "dirflg", value: "r")]
            if !from.isCurrentLocation { items.append(URLQueryItem(name: "saddr", value: from.coordinate.pair)) }
            return url("https://maps.apple.com/", items)
        }
    }

    private func url(_ base: String, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items
        return components.url!
    }
}
