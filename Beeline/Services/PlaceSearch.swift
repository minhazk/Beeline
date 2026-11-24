import MapKit
import Observation

/// Autocomplete over Apple's place search, biased to around the user. A chain
/// or a kind of place ("Apple Store", "pharmacy") finds every match nearby, to
/// choose between, rather than the first.
@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private(set) var results: [MKLocalSearchCompletion] = []

    var text = "" {
        didSet { text.isEmpty ? (results = []) : (completer.queryFragment = text) }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func bias(to coordinate: Coordinate?) {
        guard let coordinate else { return }
        completer.region = MKCoordinateRegion(center: coordinate.clLocation, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
    }

    /// The places a suggestion stands for: one for an address or a named place,
    /// several for "Apple Store — Search Nearby".
    func items(for completion: MKLocalSearchCompletion) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = completer.region
        return try await MKLocalSearch(request: request).start().mapItems
    }

    /// Everything matching what's typed, near you.
    func items(matching text: String) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = completer.region
        request.resultTypes = [.pointOfInterest, .address]
        return try await MKLocalSearch(request: request).start().mapItems
    }

    static func place(_ item: MKMapItem, title: String? = nil, subtitle: String? = nil) -> Place {
        let detail = subtitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? item.address?.shortAddress ?? item.addressRepresentations?.cityWithContext
        return Place(name: title ?? item.name ?? "Dropped pin", subtitle: detail, coordinate: Coordinate(item.location.coordinate))
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = self.completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { results = [] }
    }
}
