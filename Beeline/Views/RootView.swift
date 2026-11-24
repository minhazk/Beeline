import SwiftUI

/// One live map, one sheet over it. Pages push inside the sheet, as in Maps:
/// home, then the routes, then a journey, then Go.
struct RootView: View {
    @State private var router = Router()
    @State private var scene = MapScene()
    @State private var departures = DepartureStore()
    @State private var buses = LiveBusStore()
    @Environment(LocationService.self) private var location
    @Environment(AppSettings.self) private var settings

    var body: some View {
        MapCanvas()
            .overlay(alignment: .bottomTrailing) { MapHalf() }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let trip = router.trip {
                    // Wide open on a Duo the next turn sits over the map it describes, on the
                    // half beside the pane, off the fold.
                    GuidanceBanner(trip: trip)
                        .padding(.leading, router.foldX ?? 0)
                        // On the Duo's cover it stops at the column: the camera, the clock and its pill sit
                        // there at this height, and the pill would cut into the banner's foot.
                        // With the sheet at full height over the map it would show only at its corners.
                        .opacity(router.foldX == nil && router.detent == .large ? 0 : 1)
                        .animation(.snappy, value: router.detent)
                }
            }
            // Outside the banner's inset, so it measures the window and not the room the banner leaves.
            .background { WindowShapeReader() }
            .sheet(isPresented: .constant(true)) {
                NavigationStack(path: $router.path) {
                    HomeSheet()
                        .navigationDestination(for: Page.self) { page in
                            switch page {
                            case .results(let query): ResultsSheet(query: query)
                            case .journey(let journey, let query): JourneySheet(journey: journey, query: query)
                            case .board(let leg): BoardSheet(leg: leg)
                            case .line(let line): LineSheet(line: line)
                            }
                        }
                }
                .foregroundStyle(Theme.ink)
                .overlay { PaneCovers() }
                .alert(item: $router.tripNotice) { notice in
                    switch notice.reason {
                    case .arrived:
                        Alert(title: Text("Arrived"), message: Text(notice.destination), dismissButton: .default(Text("Done")))
                    case .expired:
                        Alert(title: Text("Trip tracking ended"), message: Text("This journey is past its arrival time."),
                              dismissButton: .default(Text("Done")))
                    }
                }
                // A rest the person drags to is remembered; one a page asks for is not.
                .presentationDetents(router.detents, selection: Binding { router.detent } set: { router.picked($0) })
                // Wide open the sheet is a pane beside the map, which stays live at every height.
                .presentationBackgroundInteraction(.enabled(upThrough: router.tallestOverMap))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
                // Wide open on a Duo: the sheet on the leading half, the map on the other.
                .sheetBesideFold(.leading, foldX: router.foldX)
                .environment(router)
                .environment(scene)
                .environment(departures)
                .environment(buses)
            }
            .environment(router)
            .environment(scene)
            .environment(departures)
            .environment(buses)
            .task { await resumeTrip() }
    }

    /// Beeline was closed during Go: back in it, on the same trip, caught up to now.
    private func resumeTrip() async {
        guard router.trip == nil, let saved = TripResume.take() else { return }
        let trip = LiveTrip(resuming: saved, location: location, departures: departures, buses: buses,
                            search: ReplanSearch.live(settings: settings), store: .shared)
        router.resume(trip)
        trip.start()
        // Switch or Keep my route tapped on the notification that opened Beeline.
        TripResume.applyHeld(to: trip)
        // After the sheet has shrunk and the banner is in: MapKit drops a follow that starts
        // while the map's insets are still moving.
        // By then Home, which appears under the journey page, has set the map to itself: the route
        // goes back on, as the journey page draws it before Go starts.
        try? await Task.sleep(for: .milliseconds(700))
        guard router.trip === trip else { return }
        scene.showJourney(trip.journey, to: trip.query.destination)
        scene.follow(near: trip.leg.start)
    }
}
