import MapKit
import Observation
import SwiftUI

/// Every screen is a page in the one sheet over the map.
enum Page: Hashable {
    case results(JourneyQuery)
    case journey(Journey, JourneyQuery)
    case board(Leg)
    case line(NearbyLine)
}

/// Where the sheet is, how tall it is, and the trip being travelled.
@MainActor @Observable
final class Router {
    var path: [Page] = []
    /// Where the sheet rests. Opens at its low rest if that is where the person left it.
    var detent: PresentationDetent = UserDefaults.standard.bool(forKey: "wholeMap") ? Router.low : .medium
    /// The sheet put away to its low rest so the map has the screen: on the Duo's cover and wide
    /// open, the two windows with that rest. Kept between launches.
    private(set) var prefersWholeMap = UserDefaults.standard.bool(forKey: "wholeMap") {
        didSet { if prefersWholeMap != oldValue { UserDefaults.standard.set(prefersWholeMap, forKey: "wholeMap") } }
    }

    /// The person dragged the sheet to a rest. Where there is a low rest, whether they put it
    /// away is remembered; a rest a page asks for (`settle`) is not.
    func picked(_ rest: PresentationDetent) {
        guard rest != detent else { return }
        detent = rest
        if covers.isEmpty, detents.contains(Self.low) { prefersWholeMap = rest == Self.low }
        // Brought the pane back up wide open: folding then shows the sheet, not the bar it was.
        if foldX != nil, rest != Self.low, foldedDetent == Self.low { foldedDetent = .medium }
    }
    struct TripNotice: Identifiable {
        let id = UUID()
        let reason: LiveTrip.Completion
        let destination: String
    }
    var tripNotice: TripNotice?

    var trip: LiveTrip? {
        didSet {
            guard oldValue !== trip else { return }
            oldValue?.onCompletion = nil
            oldValue?.stop()
            if let trip {
                tripNotice = nil
                trip.onCompletion = { [weak self, weak trip] reason in
                    guard let self, let trip, self.trip === trip else { return }
                    self.tripNotice = TripNotice(reason: reason, destination: trip.query.destination.name)
                    self.endTrip()
                }
            }
            poseChanged()
        }
    }

    /// Where the fold runs across the window, turned tall on a Duo; nil everywhere else.
    var foldY: CGFloat? {
        didSet { if foldY != oldValue { poseChanged() } }
    }
    /// The hinge is partly open, as when the phone stands on a table.
    var hingeHalfOpen = false {
        didSet { if hingeHalfOpen != oldValue { poseChanged() } }
    }
    /// Go with the phone half-open on a table: the map on the upright half, the steps on the flat one.
    var inTablePose: Bool { hingeHalfOpen && foldY != nil && trip != nil }
    /// The flat half, up to the fold.
    var tableRest: PresentationDetent {
        .height(max(Self.compactHeight, windowSize.height - (foldY ?? 0) - safeArea.bottom - 4))
    }
    /// The tallest rest that leaves the map live and lit behind the sheet.
    var tallestOverMap: PresentationDetent {
        if foldX != nil { return Self.paneFull }
        return inTablePose ? tableRest : .medium
    }
    /// What the sheet rested at flat, to go back to when the phone is laid flat again.
    private var flatDetent: PresentationDetent?

    private func poseChanged() {
        if inTablePose {
            if flatDetent == nil { flatDetent = detent }
            detent = tableRest
        } else if let flat = flatDetent {
            flatDetent = nil
            detent = flat
        }
        normalise()
    }

    /// The window, as `WindowShapeReader` last measured it, and what its safe area takes off.
    var windowSize = CGSize(width: 440, height: 956) {
        // Each shape has its own rests; a rest this one doesn't have becomes the nearest it does.
        didSet { normalise() }
    }
    var safeArea = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
    /// Where the Duo's fold runs down the window, wide open; nil everywhere else.
    var foldX: CGFloat? {
        didSet { if (foldX == nil) != (oldValue == nil) { foldChanged() } }
    }
    /// Wide open on a Duo with the sheet up: it is a pane on the leading half, beside the
    /// map rather than over it.
    var isPane: Bool { foldX != nil && detent != Self.low }
    /// What the sheet rested at before it became a pane, to go back to when the phone folds.
    private var foldedDetent: PresentationDetent?
    /// On the map half, wide open: a board, filters or a time. One at a time.
    private(set) var panel: PaneItem?
    /// Pages laid over the pane, wide open, where a phone opens a second sheet: search,
    /// Settings, Alerts. Each sits over the one that opened it.
    private(set) var covers: [PaneItem] = []
    /// The system has moved the bars into a column at the side (the Duo's cover, and wide open).
    var hasSideBar = false

    /// The bars are in a column beside a phone-width window (the Duo's cover), so a bar
    /// this app hides leaves that column empty.
    var barIsBeside: Bool { hasSideBar && foldX == nil && windowSize.width < 500 }
    /// Put away on the Duo's cover: the column beside the bar has room for its first button alone,
    /// so a page's others wait for a taller rest rather than show cut at the card's foot.
    var columnHoldsOneButton: Bool { barIsBeside && detent == Self.low }
    /// Too short to stack much above a list: under 700 pt (the Duo's cover and wide open).
    var isShort: Bool { windowSize.height < 700 }
    /// The sheet's half-height rest is shallow: on a short window, or turned tall on a Duo, where
    /// it stops at the fold with the map above. A page leads with less there.
    var sheetIsShallow: Bool { isShort || foldY != nil }
    /// Under 400 pt between the safe-area edges (about 382 on the Duo's cover, 390 on a 13 Pro):
    /// a row keeps its line and times whole and lets names give way.
    var isNarrow: Bool { windowSize.width - safeArea.leading - safeArea.trailing < 400 }
    /// Nothing of the system's above the content (the cover has no status bar), so what
    /// sits at the top needs its own margin.
    var hasNoTopInset: Bool { safeArea.top < 1 }

    /// The shortest stop of the sheet on most phones: enough for a search field or Go.
    static let compactHeight: CGFloat = 210
    static let compact = PresentationDetent.height(compactHeight)
    /// A lower rest on a short window, as Apple's Maps has: the top row alone, and the map above it.
    static let lowHeight: CGFloat = 88
    static let low = PresentationDetent.height(lowHeight)

    /// The pane's full height, wide open on a Duo. Not `.large`: the system dims what is
    /// behind a sheet at its largest rest, and the map beside the pane has to stay lit.
    static let paneFull = PresentationDetent.fraction(0.985)
    /// As tall as the sheet goes here.
    var fullRest: PresentationDetent { foldX != nil ? Self.paneFull : .large }

    /// Go's own rest, where arrival, the step's button and the next ride show over the map: 210 pt,
    /// or turned tall on a Duo about a third of the window, which has the room.
    var goRest: PresentationDetent { foldY != nil ? .height(goTallHeight) : Self.compact }
    private var goTallHeight: CGFloat { (windowSize.height / 3 - safeArea.bottom).rounded() }

    /// How tall the sheet stands over the map at a rest drawn to a height; nil for half and full.
    var restHeight: CGFloat? {
        switch detent {
        case Self.low: Self.lowHeight
        case Self.compact: Self.compactHeight
        case goRest: goTallHeight
        default: nil
        }
    }

    /// Where the sheet can rest: few, each with a job.
    var detents: Set<PresentationDetent> {
        if foldX != nil {
            // Wide open the pane is up or put away: a shorter pane beside the map shows less of
            // the list and no more of the map. A page that holds little keeps its own height.
            var rests: Set<PresentationDetent> = [Self.low, Self.paneFull]
            if let pageWideRest { rests.insert(pageWideRest) }
            return rests
        }
        if inTablePose { return [Self.compact, tableRest, .large] }
        // During Go the shortest rest is Go's own, never the bar.
        if trip != nil { return [goRest, .medium, .large] }
        // On a short window the bar, half and full; the 210 pt rest repeated half there.
        return isShort ? [Self.low, .medium, .large] : [Self.compact, .medium, .large]
    }

    /// Back in Go on a trip Polaris was closed during: its journey page, at Go's rest.
    func resume(_ trip: LiveTrip) {
        self.trip = trip
        path = [.journey(trip.journey, trip.query)]
        settle(goRest)
    }

    func endTrip() {
        trip = nil
        settle(.medium)
    }

    /// A page asking for its usual rest. Wide open the pane keeps its full height (the map
    /// is beside it, not behind), and the rest asked for is kept for when the phone folds.
    /// `wide` is the page's rest wide open on a Duo, when it is shorter than the full pane.
    func settle(_ rest: PresentationDetent, wide: PresentationDetent? = nil) {
        pageWideRest = wide
        if inTablePose {
            flatDetent = rest
        } else if foldX != nil {
            foldedDetent = rest
            detent = wide ?? Self.paneFull
        } else {
            detent = rest
        }
        normalise()
    }

    /// A page that doesn't ask for a rest on a phone (Home), coming on screen: wide open it
    /// gets the full pane back from a page that had a shorter one.
    func pageAppeared() {
        guard pageWideRest != nil else { return }
        pageWideRest = nil
        if foldX != nil, covers.isEmpty, detent != Self.low { detent = Self.paneFull }
    }

    /// The page on top asked for a shorter pane wide open, because it holds little.
    private var pageWideRest: PresentationDetent?

    private func foldChanged() {
        // The sheet put away stays put away through a fold, both ways.
        let putAway = detent == Self.low && covers.isEmpty
        if foldX != nil {
            if foldedDetent == nil { foldedDetent = detent }
            detent = putAway ? Self.low : pageWideRest ?? Self.paneFull
        } else if covers.isEmpty {
            if putAway, isShort, trip == nil {
                foldedDetent = nil
            } else {
                restoreFoldedRest()
            }
        } else {
            // With a page over the pane the sheet stays full height, folded, until that page closes.
            detent = .large
        }
        normalise()
    }

    private func restoreFoldedRest() {
        guard foldX == nil, let rest = foldedDetent else { return }
        detent = rest
        foldedDetent = nil
        normalise()
    }

    /// A rest this shape doesn't have, after a fold, a turn or Go starting or ending: the nearest
    /// one it does. A short rest during Go is Go's own; the bar becomes 210 pt where there is no
    /// bar, and back again where there is; a rest between becomes half, or wide open the full pane.
    private func normalise() {
        let rests = detents
        guard !rests.contains(detent) else { return }
        if trip != nil, rests.contains(goRest), detent != .medium, detent != .large, detent != Self.paneFull {
            detent = goRest
        } else if detent == Self.compact, prefersWholeMap, rests.contains(Self.low) {
            // Put away, turned tall (no bar there, so 210 pt) and back: put away again.
            detent = Self.low
        } else if detent == Self.low {
            detent = rests.contains(Self.compact) ? Self.compact : .medium
        } else if detent == .large || detent == Self.paneFull {
            detent = fullRest
        } else {
            detent = foldX != nil ? Self.paneFull : .medium
        }
    }

    func show(cover: PaneItem) {
        covers.removeAll { $0.id == cover.id }
        covers.append(cover)
        if detent != fullRest {
            if foldedDetent == nil { foldedDetent = detent }
            detent = fullRest
        }
    }

    /// Its page, and any opened from it.
    func hideCover(_ id: String) {
        guard let index = covers.firstIndex(where: { $0.id == id }) else { return }
        covers.removeSubrange(index...)
        if covers.isEmpty { restoreFoldedRest() }
    }

    /// One tap puts the pane away for the whole map, one brings it back.
    func toggleWholeMap() {
        guard foldX != nil else { return }
        picked(isPane ? Self.low : Self.paneFull)
    }

    func show(panel item: PaneItem) { panel = item }

    func hidePanel(_ id: String) {
        if panel?.id == id { panel = nil }
    }

    /// Closed from inside: its Done, Cancel or close button.
    func close(_ id: String) {
        if let closing = panel, closing.id == id {
            panel = nil
            closing.onClose()
        } else if let index = covers.firstIndex(where: { $0.id == id }) {
            let closing = covers[index...].reversed()
            covers.removeSubrange(index...)
            closing.forEach { $0.onClose() }
            if covers.isEmpty { restoreFoldedRest() }
        }
    }
}

/// What the map behind the sheet is showing, set by whichever page is on top.
@MainActor @Observable
final class MapScene {
    enum Content: Equatable {
        case home
        case results([Journey])
        case journey(Journey, destination: Place)
        /// A stop near you, for one line leaving it.
        case stop(Coordinate, name: String, color: RGB?)
    }

    /// Central London until the home page decides: a camera on the user's location makes
    /// MapKit ask for location by itself, which must wait for the first-run setup step.
    var position: MapCameraPosition = MapScene.overview
    static let overview = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.509, longitude: -0.118), span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)))
    /// False while the setup step is up: the map shows the overview and asks nothing.
    var mayUseLocation = true
    /// Which way the map is turned, so your heading beam can turn against it.
    var cameraHeading: Double = 0
    private(set) var content = Content.home
    /// The leg picked in the itinerary, drawn on top.
    private(set) var focusedLeg: UUID?
    /// The bus line drawn live, if any (Go's own ride wins over this).
    private(set) var busWatch: BusWatch?
    /// Places a search turned up, pinned while the search is a page beside the map.
    private(set) var pins: [Place] = []

    var isJourney: Bool { if case .journey = content { true } else { false } }

    func showHome() {
        content = .home
        focusedLeg = nil
        busWatch = nil
        lastFrame = nil
        withAnimation(.smooth) { position = mayUseLocation ? .userLocation(fallback: .automatic) : Self.overview }
    }

    func showResults(_ journeys: [Journey]) {
        let top = Array(journeys.prefix(4))
        busWatch = nil
        guard content != .results(top) else { return }
        content = .results(top)
        frame(top.flatMap { $0.legs.flatMap(\.path) })
    }

    func showJourney(_ journey: Journey, to destination: Place) {
        content = .journey(journey, destination: destination)
        focusedLeg = nil
        busWatch = nil
        frame(journey.legs.flatMap(\.path))
    }

    func focus(_ leg: Leg) {
        focusedLeg = leg.id
        busWatch = BusWatch(leg: leg)
        frame(leg.path)
    }

    /// A ride's boarding stop, with its buses coming in.
    func showBoarding(_ leg: Leg) {
        busWatch = BusWatch(leg: leg)
        if let start = leg.start { frame([start], margin: busWatch == nil ? 250 : 700) }
    }

    /// A stop near you and one line leaving it, live where it's a London bus.
    func showStop(_ line: NearbyLine) {
        content = .stop(line.stopCoordinate, name: line.stopName, color: line.lineColor)
        focusedLeg = nil
        busWatch = BusWatch(nearby: line)
        frame([line.stopCoordinate], margin: busWatch == nil ? 250 : 700)
    }

    /// Follow you, turning with you, as Go does. Until there's a fix, sit close
    /// over `near` (where the trip starts) rather than the whole route.
    func follow(near: Coordinate? = nil) {
        lastFrame = nil
        followAskedAt = .now
        followRetries = 0
        applyFollow(near: near)
    }

    /// Re-follows when the map dropped it within moments of being asked, which
    /// is layout settling rather than you panning.
    func resumeFollowingIfJustAsked(near: Coordinate?) {
        guard let asked = followAskedAt, Date.now.timeIntervalSince(asked) < 3, followRetries < 4 else { return }
        followRetries += 1
        applyFollow(near: near)
    }

    private var followAskedAt: Date?
    private var followRetries = 0

    private func applyFollow(near: Coordinate?) {
        // Setting a position equal to the current one does nothing, so a second
        // call (once the first fix arrives) would be lost; alternate the fallback.
        followNudge.toggle()
        let fallback: MapCameraPosition = near.map {
            .camera(MapCamera(centerCoordinate: $0.clLocation, distance: followNudge ? 900 : 901))
        } ?? .automatic
        withAnimation(.smooth) { position = .userLocation(followsHeading: Self.headingAvailable, fallback: fallback) }
    }

    private var followNudge = false

    /// The simulator has no compass, and asking to follow a heading there means
    /// not following at all.
    #if targetEnvironment(simulator)
    private static let headingAvailable = false
    #else
    private static let headingAvailable = true
    #endif

    func showPins(_ places: [Place]) {
        pins = places
        frame(places.map(\.coordinate), margin: 400)
    }

    func clearPins() { pins = [] }

    func frame(_ coordinates: [Coordinate], margin: Double = 250) {
        guard !coordinates.isEmpty else { return }
        lastFrame = (coordinates, margin)
        movedByYou = false
        applyFrame()
    }

    /// The share of the map's width its buttons take down the trailing side, where that is
    /// enough to hide the end of a route (a map under 400 pt wide). Set by the map.
    var buttonLane: Double = 0

    /// What was framed last, to frame again when the window changes shape.
    private var lastFrame: (coordinates: [Coordinate], margin: Double)?
    /// You have panned or zoomed since: a fold or a turn keeps your view then.
    private var movedByYou = false
    private var shapeChangedAt = Date.distantPast
    private var frameNudge = false

    /// A fold, a turn, a new rest for the sheet or a panel on the map: MapKit keeps the old centre
    /// and zoom, which can leave a route off the edge or under the sheet. Frame it again once
    /// the layout has settled; a move MapKit reports meanwhile is the layout, not you.
    func windowChangedShape() {
        shapeChangedAt = .now
    }

    func reframeAfterShapeChange() {
        guard lastFrame != nil, !movedByYou else { return }
        applyFrame()
    }

    func setButtonLane(_ share: Double) {
        guard abs(share - buttonLane) > 0.001 else { return }
        buttonLane = share
    }

    /// The map reports a move by you; a resize settling within moments of a fold reads the same.
    func positionedByUser() {
        if Date.now.timeIntervalSince(shapeChangedAt) > 1.5 { movedByYou = true }
    }

    private func applyFrame() {
        guard let (coordinates, margin) = lastFrame else { return }
        let rect = coordinates.reduce(MKMapRect.null) { rect, c in
            rect.union(MKMapRect(origin: MKMapPoint(c.clLocation), size: MKMapSize(width: 1, height: 1)))
        }
        // A margin round the route, and a floor so a short walk isn't street-level. Setting
        // the same position again does nothing, so a reframe changes it by a hair.
        frameNudge.toggle()
        let pad = (max(rect.width, rect.height) * 0.18 + margin) * (frameNudge ? 1 : 1.0001)
        var framed = rect.insetBy(dx: -pad, dy: -pad)
        // Keep the route out from under the map's buttons on a narrow map.
        if buttonLane > 0 { framed.size.width += framed.width * buttonLane / (1 - buttonLane) }
        withAnimation(.smooth) { position = .rect(framed) }
    }
}
