import Foundation
import Testing
@testable import Polaris

/// Parsers against real responses recorded for King's Cross → Canary Wharf.
struct ProviderParsingTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: Marker.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func transitous() throws {
        let journeys = try TransitousProvider.parse(Self.fixture("transitous-plan"), origin: "King's Cross", destination: "Canary Wharf")
        let first = try #require(journeys.first)
        #expect(first.legs.first?.fromName == "King's Cross")
        #expect(first.legs.last?.toName == "Canary Wharf")
        #expect(first.transitLegs.map(\.mode) == [.tube, .elizabeth])
        #expect(first.transitLegs.map(\.line) == ["Hammersmith & City", "Elizabeth line"])
        #expect(first.duration == 30 * 60)
        #expect(first.legs.allSatisfy { !$0.path.isEmpty })
        #expect(first.transitLegs.first?.platform == "2")
        #expect(first.transitLegs.last?.intermediateStops == ["Liverpool Street", "Whitechapel"])
        // Decoded at precision 6, the path stays in London.
        let point = try #require(first.transitLegs.first?.path.first)
        #expect((51.4...51.6).contains(point.latitude) && (-0.3...0.1).contains(point.longitude))
    }

    @Test func tfl() throws {
        let journeys = try TfLProvider.parse(Self.fixture("tfl-journeys"), variant: "Fastest")
        let first = try #require(journeys.first)
        #expect(first.transitLegs.map(\.mode) == [.tube, .dlr])
        #expect(first.transitLegs.first?.line == "Northern")
        #expect(first.transitLegs.first?.fromName == "King's Cross St. Pancras")
        // TfL lists the alighting stop last; only the ones in between are kept.
        #expect(first.transitLegs.first?.intermediateStops == ["Angel", "Old Street", "Moorgate"])
        #expect(first.duration == 39 * 60)
        // London wall-clock "11:58" in GMT season.
        #expect(first.departure == Time.iso("2026-10-28T11:58:00Z"))
        #expect(journeys.contains { $0.transitLegs.map(\.mode) == [.rail, .elizabeth] })
    }

    @Test func google() throws {
        let query = JourneyQuery(
            origin: Place(name: "King's Cross", coordinate: .init(latitude: 51.5308, longitude: -0.1238)),
            destination: Place(name: "Canary Wharf", coordinate: .init(latitude: 51.5035, longitude: -0.0187)), time: .leaveNow)
        let journeys = try GoogleRoutesProvider.parse(Self.fixture("google-routes"), query: query, variant: "Fastest")
        #expect(journeys.count == 6)
        let first = try #require(journeys.first)
        #expect(first.transitLegs.map(\.mode) == [.tube, .dlr])
        #expect(first.transitLegs.map(\.line) == ["Northern", "DLR"])
        #expect(first.fare == "£3.10")
        // Matches the route Transitous and TfL also find, so the cards can merge.
        let hc = try #require(journeys.first { $0.transitLegs.map(\.mode) == [.tube, .elizabeth] })
        #expect(hc.transitLegs.map(\.line) == ["Hammersmith & City", "Elizabeth line"])
        #expect(hc.legs.map(\.mode) == [.walk, .tube, .walk, .elizabeth, .walk])
        #expect(hc.legs[0].toName == "King's Cross St. Pancras")
        #expect(hc.legs.last?.toName == "Canary Wharf")
        #expect(hc.legs.allSatisfy { !$0.path.isEmpty })
        #expect(hc.departure == hc.legs[1].departure.addingTimeInterval(-180))
    }

    @Test func googleSynthetic() throws {
        let json = """
        {"routes":[{"duration":"1500s","localizedValues":{"transitFare":{"text":"£2.80"}},"legs":[{"steps":[
          {"travelMode":"WALK","staticDuration":"120s","distanceMeters":150},
          {"travelMode":"WALK","staticDuration":"60s","distanceMeters":50},
          {"travelMode":"TRANSIT","staticDuration":"600s","transitDetails":{"stopDetails":{
            "departureStop":{"name":"King's Cross St. Pancras"},"arrivalStop":{"name":"Farringdon"},
            "departureTime":"2026-10-28T12:05:00Z","arrivalTime":"2026-10-28T12:08:00Z"},
            "headsign":"Barking","stopCount":2,
            "transitLine":{"name":"Hammersmith & City","color":"#f3a9bb","vehicle":{"type":"SUBWAY"}}}},
          {"travelMode":"TRANSIT","transitDetails":{"stopDetails":{
            "departureStop":{"name":"Farringdon"},"arrivalStop":{"name":"Canary Wharf"},
            "departureTime":"2026-10-28T12:12:00Z","arrivalTime":"2026-10-28T12:22:00Z"},
            "transitLine":{"name":"Elizabeth line","vehicle":{"type":"HEAVY_RAIL"}}}},
          {"travelMode":"WALK","staticDuration":"300s","distanceMeters":400}
        ]}]}]}
        """
        let query = JourneyQuery(
            origin: Place(name: "A", coordinate: .init(latitude: 51.53, longitude: -0.12)),
            destination: Place(name: "B", coordinate: .init(latitude: 51.50, longitude: -0.02)), time: .leaveNow)
        let journey = try #require(GoogleRoutesProvider.parse(Data(json.utf8), query: query, variant: "Fastest").first)
        #expect(journey.legs.map(\.mode) == [.walk, .tube, .elizabeth, .walk])
        #expect(journey.departure == Time.iso("2026-10-28T12:02:00Z"))
        #expect(journey.arrival == Time.iso("2026-10-28T12:27:00Z"))
        #expect(journey.legs[0].toName == "King's Cross St. Pancras")
        #expect(journey.legs[3].toName == "B")
        #expect(journey.fare == "£2.80")
    }

    @Test func polyline() {
        // Google's documented example.
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 1e-6 && abs(points[0].longitude + 120.2) < 1e-6)
        #expect(abs(points[2].latitude - 43.252) < 1e-6 && abs(points[2].longitude + 126.453) < 1e-6)
    }

    @Test func providerRedirectsStayOnTheOriginalHTTPSOrigin() {
        let origin = URL(string: "https://api.tfl.gov.uk/Line")
        #expect(ProviderRedirects.permits(from: origin, to: URL(string: "https://API.TFL.GOV.UK:443/Line/Status")))
        for url in ["http://api.tfl.gov.uk/", "https://api.tfl.gov.uk:8443/", "https://example.org/"] {
            #expect(!ProviderRedirects.permits(from: origin, to: URL(string: url)))
        }
    }

    @Test func onlyTransitousReceivesTheContactEnteredOnThePhone() {
        let contact = "rider@example.org"
        for host in ["routes.googleapis.com", "api.tfl.gov.uk", "alerts.example.org", "api.transitous.org"] {
            let agent = HTTP.userAgent(for: URL(string: "https://\(host)/"), transitousContact: contact)
            #expect(agent.contains(contact) == (host == "api.transitous.org"))
        }
    }

    @Test func incompleteOrUnsupportedGeometryHasNoMapPath() {
        #expect(Polyline.decode("???").isEmpty)
        #expect(Polyline.decode("??", precision: -1).isEmpty)
    }
}

private final class Marker {}
