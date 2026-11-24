import Foundation
import Testing
@testable import Polaris

@MainActor
struct PlaceStoreTests {
    @Test func favoritesRoundTripAlongsidePreviouslySavedPlaces() throws {
        let suite = "PlaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = JourneyQuery.londonExample.origin
        let favorite = JourneyQuery.londonExample.destination
        defaults.set(try JSONEncoder().encode(home), forKey: "places.home")
        let store = PlaceStore(defaults: defaults)
        #expect(store.favorites.isEmpty)
        store.addFavorite(favorite)
        store.addFavorite(Place(name: favorite.name, coordinate: favorite.coordinate))
        let reopened = PlaceStore(defaults: defaults)
        #expect(reopened.home == home)
        #expect(reopened.favorites == [favorite])
        reopened.removeFavorite(favorite)
        #expect(PlaceStore(defaults: defaults).favorites.isEmpty)
    }
}
