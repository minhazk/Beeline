import MapKit
import SwiftUI

/// The one map behind every page: nearby stops at home, the candidate routes
/// while comparing, one journey in detail, and you, moving, during Go.
struct MapCanvas: View {
    @Environment(MapScene.self) private var scene
    @Environment(Router.self) private var router
    @Environment(DepartureStore.self) private var departures
    @Environment(LocationService.self) private var location
    @Environment(LiveBusStore.self) private var buses
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var height: CGFloat = 800
    /// The map is turned away from north, so the compass shows in place of 3D.
    @State private var isTurned = false
    @State private var satellite = false
    @State private var restingCamera: MapCamera?
    @State private var showsLocationNotice = false
    /// The map's own buttons live outside it, in the lane under the clock.
    @Namespace private var mapScope

    /// Go's ride wins over whatever the page asked to show.
    private var busWatch: BusWatch? { router.trip?.busWatch ?? scene.busWatch }

    var body: some View {
        @Bindable var scene = scene
        Map(position: $scene.position, scope: mapScope) {
            // Annotations don't inherit the environment; passing the objects (not their
            // values) keeps the compass and the map turning from redrawing everything.
            // Only once allowed: MapKit asks for location itself when it has a user annotation.
            if location.isAuthorized {
                UserAnnotation { LocationDot().environment(location).environment(scene) }
            }
            // Underground the phone keeps the platform's fix: where the ride has got to by the
            // clock, drawn hollow so it reads as an estimate, not a fix.
            if let estimate = router.trip?.estimatedPosition {
                Annotation("", coordinate: estimate.clLocation, anchor: .center) { EstimatedDot() }
                    .annotationTitles(.hidden)
            }
            if case .home = scene.content, scene.pins.isEmpty { nearbyStops }
            ForEach(scene.pins) { place in
                Marker(place.name, coordinate: place.coordinate.clLocation).tint(Theme.tint)
            }
            if let busWatch {
                // The whole route only where no journey line already shows the way.
                LiveBusLayer(store: buses, watch: busWatch, yours: router.trip?.yourBus?.id,
                             drawsRoute: !scene.isJourney, scene: scene)
            }
            if case .stop(let coordinate, let name, let color) = scene.content {
                Annotation(name, coordinate: coordinate.clLocation) { StopDot(color: color) }
            }
            if case .results(let journeys) = scene.content {
                ForEach(Array(journeys.enumerated().reversed()), id: \.element.id) { index, journey in
                    JourneyLines(journey: journey, dimmed: index > 0)
                }
            }
            if case .journey(let shown, let destination) = scene.content {
                // During Go, the trip's own journey: after a switch, the new way.
                let journey = router.trip?.journey.id == shown.id ? router.trip!.journey : shown
                JourneyLines(journey: journey, dimmed: false, walkOverride: router.trip?.walk?.path,
                             activeLeg: router.trip.map { $0.leg.id } ?? scene.focusedLeg)
                JourneyStops(journey: journey, destination: destination)
                // A faster way on offer, outlined in blue over the current one, to see where it goes.
                if let offer = router.trip?.offer {
                    JourneyLines(journey: offer.journey, dimmed: false, casing: Theme.tint)
                }
            }
        }
        .mapStyle(mapStyle)
        .mapControls { MapScaleView() }
        // Frame routes in the part of the map the sheet leaves showing: above it, or,
        // wide open on a Duo, the half beside it.
        .safeAreaPadding(.bottom, bottomInset)
        .safeAreaPadding(.leading, leadingInset)
        .overlay(alignment: .bottom) {
            if !router.hasSideBar, router.detent != .large {
                phoneMapControls.padding(.bottom, router.detent == .medium ? router.windowSize.height / 2 + 8 : bottomInset + 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if router.hasSideBar { MapButtons(scope: mapScope, isTurned: isTurned) }
        }
        .mapScope(mapScope)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onMapCameraChange(frequency: .continuous) { context in
            scene.cameraHeading = context.camera.heading
            // Only when it flips: the map's body doesn't follow the heading itself.
            let turned = Self.isTurned(context.camera.heading)
            if turned != isTurned { isTurned = turned }
        }
        .onMapCameraChange(frequency: .onEnd) { restingCamera = $0.camera }
        .alert("Location is off", isPresented: $showsLocationNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Allow location in Settings to center the map on you.")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { location.startHeading() } else { location.stopHeading() }
        }
        // The sheet shrinking and the banner arriving as Go starts reach MapKit as
        // if you'd moved the map, which ends following; take it back while that settles.
        .onChange(of: scene.position.positionedByUser) { _, byUser in
            guard byUser else { return }
            scene.positionedByUser()
            if let trip = router.trip { scene.resumeFollowingIfJustAsked(near: trip.leg.start) }
        }
        // A fold, a turn, a new rest for the sheet or a panel on the map half: frame what was on
        // show again in the part of the map left showing, unless you've moved the map yourself,
        // once the sheet and its insets have settled. MapKit keeps its old centre otherwise, and
        // after a rest change the route could end up a town away.
        .onChange(of: visibleArea) { scene.windowChangedShape() }
        .onChange(of: mapWidth, initial: true) { _, width in
            // The location, compass and 3D buttons run down the trailing side, about 56 pt.
            scene.setButtonLane(width < 400 && width > 0 ? 56 / width : 0)
        }
        .task(id: visibleArea) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            scene.reframeAfterShapeChange()
        }
        // Live buses for whichever line is on show, while the app is open; the task
        // ends (and with it the 30-second refresh) when the map moves on.
        .task(id: BusTask(watch: busWatch, active: scenePhase == .active)) {
            guard let busWatch, scenePhase == .active else {
                if busWatch == nil { buses.clear() }
                return
            }
            await buses.run(busWatch, appKey: settings.tflKey)
        }
        // Stood half-open on a table, the map has only the upright half: centre you in it again.
        .onChange(of: router.inTablePose) {
            if let trip = router.trip { scene.follow(near: trip.leg.start) }
        }
        // Go starts before the first fix more often than not; pick you up when it comes.
        .onChange(of: router.trip?.position != nil) { _, located in
            if located, let trip = router.trip { scene.follow(near: trip.leg.start) }
        }
    }

    private var mapStyle: MapStyle {
        if satellite { return .hybrid(elevation: .realistic) }
        switch scene.content {
        case .results, .journey: return .standard(elevation: .realistic, emphasis: .muted)
        default: return .standard(elevation: .realistic)
        }
    }

    private var phoneMapControls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom) {
                Button {
                    guard var camera = restingCamera else { return }
                    if isTurned { camera.heading = 0 } else { camera.pitch = camera.pitch > 10 ? 0 : 55 }
                    withAnimation(.smooth) { scene.position = .camera(camera) }
                } label: {
                    Group {
                        if isTurned { Image(systemName: "location.north.line.fill") }
                        else { Text((restingCamera?.pitch ?? 0) > 10 ? "2D" : "3D").monospacedDigit() }
                    }
                    .font(.headline)
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(isTurned ? "Point north" : (restingCamera?.pitch ?? 0) > 10 ? "Switch to 2D" : "Switch to 3D")
                Spacer()
                VStack(spacing: 0) {
                    Menu {
                        Picker("Map style", selection: $satellite) {
                            Label("Standard", systemImage: "map").tag(false)
                            Label("Satellite", systemImage: "globe").tag(true)
                        }
                    } label: {
                        Image(systemName: "map.fill").font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Map style")
                    Divider().frame(width: 30)
                    Button {
                        guard !location.isDenied else { showsLocationNotice = true; return }
                        location.requestPermission()
                        if let trip = router.trip { scene.follow(near: trip.leg.start) }
                        else { scene.centerOnLocation(near: location.last) }
                    } label: {
                        Image(systemName: scene.position.followsUserLocation ? "location.fill" : "location")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Center on my location")
                }
                .glassEffect(.regular, in: .capsule)
            }
            .tint(.primary)
            .padding(.horizontal, 18)
        }
    }

    /// The window and the part of it the sheet, pane or panel leaves for the map.
    private struct VisibleArea: Equatable {
        var window: CGSize
        var bottom: CGFloat
        var leading: CGFloat
    }

    private var visibleArea: VisibleArea {
        VisibleArea(window: router.windowSize, bottom: bottomInset.rounded(), leading: leadingInset)
    }

    private var leadingInset: CGFloat { router.isPane ? router.foldX ?? 0 : 0 }

    /// Turned away from north by more than a hair.
    private static func isTurned(_ heading: Double) -> Bool {
        let heading = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return min(heading, 360 - heading) > 1
    }

    private struct BusTask: Equatable {
        var watch: BusWatch?
        var active: Bool
    }

    /// How wide the map is where routes are framed: the window inside its safe area, less the pane.
    private var mapWidth: CGFloat {
        router.windowSize.width - router.safeArea.leading - router.safeArea.trailing - (router.isPane ? router.foldX ?? 0 : 0)
    }

    private var bottomInset: CGFloat {
        // Half-open on a table during Go: the map has the upright half.
        if router.inTablePose, let foldY = router.foldY { return router.windowSize.height - foldY - router.safeArea.bottom }
        guard router.foldX != nil else { return sheetInset }
        // Wide open: clear of a panel docked on the map half, or of the sheet at its low rest.
        if router.isPane { return router.panel.map { $0.height + 16 } ?? 0 }
        return Router.lowHeight
    }

    private var sheetInset: CGFloat { router.restHeight ?? height * 0.48 }

    @MapContentBuilder private var nearbyStops: some MapContent {
        let lines = departures.nearby?.value ?? []
        let stops = Dictionary(grouping: lines, by: \.stopName).compactMap { $0.value.first }
        ForEach(stops) { line in
            Annotation(line.stopName, coordinate: line.stopCoordinate.clLocation) {
                Button { router.path.append(.line(line)) } label: {
                    Image(systemName: line.mode.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Theme.paper.opacity(0.85), in: .circle)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(8)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(line.stopName), \(line.line)")
            }
            .annotationTitles(.hidden)
        }
    }
}

/// You on the map: the blue dot, with a beam the way the phone points, as Apple
/// Maps draws it, so coming out of a station you can see which way to start walking.
/// Its own view, so the compass and the map turning redraw only this.
struct LocationDot: View {
    @Environment(LocationService.self) private var location
    @Environment(MapScene.self) private var scene

    var body: some View {
        ZStack {
            if let heading = location.heading {
                // A vaguer compass gets a wider beam.
                HeadingBeam(spread: min(max(heading.accuracy * 2, 40), 110))
                    .fill(RadialGradient(colors: [Theme.tint.opacity(0.55), Theme.tint.opacity(0)],
                                         center: .center, startRadius: 6, endRadius: 58))
                    .rotationEffect(.degrees(heading.degrees - scene.cameraHeading))
            }
            Circle().fill(.white).frame(width: 22, height: 22).shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
            Circle().fill(Theme.tint).frame(width: 15, height: 15)
        }
        .frame(width: 120, height: 120)
        .allowsHitTesting(false)
        .accessibilityLabel(location.heading.map { "You, facing \(Self.compass($0.degrees))" } ?? "You")
    }

    static func compass(_ degrees: Double) -> String {
        let points = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return points[Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45)) % 8]
    }
}

/// Where your ride has probably got to with no fix: a dashed ring, not the solid dot.
struct EstimatedDot: View {
    var body: some View {
        Circle()
            .fill(Theme.tint.opacity(0.15))
            .strokeBorder(Theme.tint, style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
            .frame(width: 22, height: 22)
            .allowsHitTesting(false)
            .accessibilityLabel("Your ride, about here by the clock")
    }
}

/// A wedge from the centre, pointing up, `spread` degrees wide.
struct HeadingBeam: Shape {
    var spread: Double

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90 - spread / 2), endAngle: .degrees(-90 + spread / 2), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A journey's legs: lines in their own colours over a casing, walks dotted.
struct JourneyLines: MapContent {
    var journey: Journey
    var dimmed: Bool
    /// A live walking route that replaces the source's path for the walk you're on.
    var walkOverride: [Coordinate]?
    var activeLeg: UUID?
    /// The edge under each line: the map casing or the blue outline for a faster alternative.
    var casing: Color = Theme.casing

    var body: some MapContent {
        ForEach(journey.legs) { leg in
            let path = leg.id == activeLeg && !leg.mode.isTransit ? (walkOverride ?? leg.path) : leg.path
            if path.count > 1 {
                if leg.mode.isTransit {
                    MapPolyline(coordinates: path.map(\.clLocation))
                        .stroke(casing.opacity(dimmed ? 0.6 : 1), style: StrokeStyle(lineWidth: dimmed ? 6 : 9, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: path.map(\.clLocation))
                        .stroke(dimmed ? Theme.ink.opacity(0.28) : Theme.line(leg.lineColor),
                                style: StrokeStyle(lineWidth: dimmed ? 3 : 5.5, lineCap: .round, lineJoin: .round))
                } else {
                    let live = leg.id == activeLeg && walkOverride != nil
                    MapPolyline(coordinates: path.map(\.clLocation))
                        .stroke(live ? Theme.tint : Theme.ink.opacity(dimmed ? 0.3 : 0.65),
                                style: StrokeStyle(lineWidth: live ? 5 : 3.5, lineCap: .round, lineJoin: .round,
                                                   dash: live ? [] : [0.5, 7]))
                }
            }
        }
    }
}

/// Where you board and get off, labelled like an atlas, and the destination's star.
struct JourneyStops: MapContent {
    var journey: Journey
    var destination: Place

    var body: some MapContent {
        ForEach(journey.transitLegs) { leg in
            if let start = leg.start {
                Annotation(leg.fromName, coordinate: start.clLocation) { StopDot(color: leg.lineColor) }
            }
            if let end = leg.end {
                Annotation(leg.toName, coordinate: end.clLocation) { StopDot(color: leg.lineColor) }
            }
        }
        if let start = journey.legs.first?.start, !journey.legs.isEmpty {
            Annotation("", coordinate: start.clLocation) {
                Circle().fill(Theme.tint).stroke(.white, lineWidth: 2.5).frame(width: 14, height: 14)
            }
        }
        Annotation(destination.name, coordinate: (journey.legs.last?.end ?? destination.coordinate).clLocation) {
            FractalStar(size: 30)
                .background(Circle().fill(Theme.surface).frame(width: 22, height: 22))
        }
    }
}

private struct StopDot: View {
    var color: RGB?

    var body: some View {
        Circle()
            .fill(Theme.surface)
            .stroke(color == nil ? Theme.ink : Theme.line(color), lineWidth: 3)
            .frame(width: 13, height: 13)
    }
}

/// The map's floating buttons in one lane, the same in every shape. Where the system's bars are
/// down the side (the Duo's cover, and wide open) that is under the clock, on its axis, as Apple's
/// Find My and Maps place theirs; MapKit's default put them 16 pt inside the content edge, lined
/// up with nothing. Elsewhere it is the phone's top trailing corner, which is under the clock too.
/// Locate, then 3D, or the compass while the map is turned so the lane stays two buttons tall and
/// clear of the cover's half-height sheet; wide open, the whole-map button at its foot.
struct MapButtons: View {
    let scope: Namespace.ID
    var isTurned: Bool
    @Environment(Router.self) private var router

    var body: some View {
        // One glass capsule: MapKit draws its buttons bare outside the map.
        VStack(spacing: 0) {
            MapUserLocationButton(scope: scope)
            divider
            if isTurned {
                MapCompass(scope: scope)
            } else {
                MapPitchToggle(scope: scope)
            }
            if showsWholeMap {
                divider
                wholeMapButton
            }
        }
        .frame(width: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, top)
        .padding(.trailing, trailing)
        .ignoresSafeArea(edges: inColumn ? [.top, .trailing] : [])
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 26, height: 0.75)
    }

    /// The system's column is down the trailing side.
    private var inColumn: Bool { router.hasSideBar && (router.foldX != nil || router.barIsBeside) }

    /// Measured on the simulator: the clock's axis sits 35 pt into the column (x 417 on the
    /// cover, 902 wide open), and the lane starts under the clock and its status ring.
    private var top: CGFloat {
        guard inColumn else { return 16 }
        return router.foldX != nil ? 124 : 174
    }

    private var trailing: CGFloat {
        guard inColumn else { return 16 }
        return router.safeArea.trailing - 35 - 22
    }

    /// Wide open with no panel docked on the map half and no page over the pane.
    private var showsWholeMap: Bool {
        router.foldX != nil && router.covers.isEmpty && !(router.isPane && router.panel != nil)
    }

    private var wholeMapButton: some View {
        Button {
            router.toggleWholeMap()
        } label: {
            Image(systemName: router.isPane ? "arrow.up.left.and.arrow.down.right" : "sidebar.leading")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.tint)
        .accessibilityLabel(router.isPane ? "Whole map" : "Show panel")
        .accessibilityHint(router.isPane ? "Puts the panel away so the map fills the screen" : "Brings the panel back beside the map")
    }
}
