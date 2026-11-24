import MapKit
import SwiftUI

/// A bus on the map, in its line's colour, with a chevron the way it's going and,
/// for one still to reach your stop, how soon it's there.
struct BusMarker: View {
    var bus: TfLBuses.Bus
    var color: RGB?
    var label: String?
    var isYours: Bool
    /// Passed in: map annotations don't inherit the environment.
    var scene: MapScene

    var body: some View {
        let fill = Theme.line(color)
        VStack(spacing: 1) {
            ZStack {
                if let heading = bus.heading {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(fill)
                        .shadow(color: .white, radius: 0.5)
                        .offset(y: -18)
                        .rotationEffect(.degrees(heading - scene.cameraHeading))
                }
                Image(systemName: "bus.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle((color?.luminance ?? 0) < 0.6 ? Color.white : Color.black)
                    .frame(width: 24, height: 24)
                    .background(fill, in: .circle)
                    .overlay(Circle().strokeBorder(isYours ? Theme.tint : .white, lineWidth: isYours ? 3 : 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .frame(width: 44, height: 44)
            if let label {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.surface, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .offset(y: -8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isYours ? "Your bus" : label.map { "Bus, at your stop in \($0)" } ?? "Bus")
    }
}

/// The live buses on a map: the route faint underneath, then each bus.
struct LiveBusLayer: MapContent {
    var store: LiveBusStore
    var watch: BusWatch
    var yours: String?
    var drawsRoute: Bool
    var scene: MapScene

    var body: some MapContent {
        if store.watch == watch, let route = store.route {
            if drawsRoute {
                MapPolyline(coordinates: route.path.map(\.clLocation))
                    .stroke(Theme.line(watch.color).opacity(0.4), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            let due = Dictionary(store.approaching.map { ($0.bus.id, $0) }, uniquingKeysWith: { a, _ in a })
            ForEach(store.drawn) { bus in
                Annotation("", coordinate: bus.coordinate.clLocation) {
                    BusMarker(bus: bus, color: watch.color, label: due[bus.id].map { Self.label($0, now: store.now) },
                              isYours: bus.id == yours, scene: scene)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    static func label(_ approach: LiveBusStore.Approach, now: Date) -> String {
        let minutes = Int(approach.due.timeIntervalSince(now) / 60)
        return minutes < 1 ? "Due" : "\(minutes) min"
    }
}

/// The next buses to your stop, in a line: "3 min, 2 stops away · then 9, 15 min".
struct LiveBusSummary: View {
    var watch: BusWatch

    @Environment(LiveBusStore.self) private var store

    var body: some View {
        if store.watch == watch {
            let approaching = store.approaching
            Group {
                if let first = approaching.first {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next bus \(Self.when(first, now: store.now))").font(.subheadline.weight(.semibold))
                            Text(detail(first, later: approaching.dropFirst().prefix(2).map { $0 }))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        LiveDot()
                    }
                } else if let problem = store.problem {
                    Label(problem, systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if store.updatedAt != nil {
                    Label("No buses on the way to this stop right now", systemImage: "bus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Finding the buses…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .surface()
            // The buses glide on the map; words just change.
            .transaction { $0.animation = nil }
        }
    }

    static func when(_ approach: LiveBusStore.Approach, now: Date) -> String {
        let minutes = Int(approach.due.timeIntervalSince(now) / 60)
        return minutes < 1 ? "due now" : "in \(minutes) min"
    }

    private func detail(_ first: LiveBusStore.Approach, later: [LiveBusStore.Approach]) -> String {
        let away = Self.stopsAway(first)
        guard !later.isEmpty else { return away }
        let minutes = later.map { max(0, Int($0.due.timeIntervalSince(store.now) / 60)) }
        return "\(away) · then \(minutes.map(String.init).joined(separator: ", ")) min"
    }

    static func stopsAway(_ approach: LiveBusStore.Approach) -> String {
        if approach.bus.waiting { return approach.stopsAway == 0 ? "Starts here" : "Starts from \(approach.near)" }
        switch approach.stopsAway {
        case 0: return "Your stop is next"
        case 1: return "1 stop away, at \(approach.near)"
        default: return "\(approach.stopsAway) stops away, at \(approach.near)"
        }
    }
}

/// A line leaving a stop near you: the next ones, and for London buses, where each
/// bus is now on the map.
struct LineSheet: View {
    let line: NearbyLine

    @Environment(MapScene.self) private var scene
    @Environment(Router.self) private var router
    @Environment(LiveBusStore.self) private var store
    /// The map has been moved to show the next bus coming.
    @State private var framedBus = false

    private var watch: BusWatch? { BusWatch(nearby: line) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let watch {
                    live(watch)
                } else {
                    timetable
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        // A bus stop's full name is often longer than the title row ("King's Cross St. Pancras
        // Underground Station") and is in the header below, so the title is its stop letter. The
        // system's own title, as on every other page, so it sits where theirs do: on the leading
        // side on the Duo's cover, centred elsewhere.
        .navigationTitle(stopLetter.map { "Stop \($0)" } ?? line.stopName)
        .lowRestBar()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            scene.showStop(line)
            // Opened from a full-height sheet there'd be no map to show the stop or its buses
            // on. Half height shows both; drag the sheet up by its top for more of the list.
            // Wide open a line holds a few rows, so its pane rests at half height, not full.
            router.settle(.medium, wide: .medium)
        }
        // Once the route's in, show the stretch the buses come along, then the next one coming.
        .onChange(of: store.route) { _, route in
            guard !framedBus, let route, let stop = store.stopIndex, store.watch == watch else { return }
            let before = route.stops[max(0, stop - 6)...stop].map(\.coordinate)
            scene.frame(before + [line.stopCoordinate])
        }
        .onChange(of: store.approaching.first?.id) { _, id in
            guard !framedBus, id != nil, store.watch == watch, let next = store.approaching.first else { return }
            framedBus = true
            scene.frame([line.stopCoordinate, next.bus.coordinate], margin: 400)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LinePill(mode: line.mode, line: line.line, color: line.lineColor, compact: false)
                Text(line.headsign.isEmpty ? line.line : "to \(line.headsign)")
                    .font(.headline)
                    .lineLimit(2)
            }
            Text(stopText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var stopLetter: String? {
        guard store.watch == watch, let route = store.route, let stop = store.stopIndex else { return nil }
        return route.stops[stop].letter
    }

    private var stopText: String {
        var parts = [line.stopName]
        if store.watch == watch, let route = store.route, let stop = store.stopIndex, let letter = route.stops[stop].letter {
            parts[0] += ", stop \(letter)"
        }
        parts.append("\(Int((line.distance / 10).rounded()) * 10) m away")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func live(_ watch: BusWatch) -> some View {
        let approaching = store.watch == watch ? store.approaching : []
        if approaching.isEmpty {
            LiveBusSummary(watch: watch)
            timetable
        } else {
            VStack(spacing: 0) {
                ForEach(Array(approaching.prefix(6).enumerated()), id: \.element.id) { index, approach in
                    if index > 0 { Divider().padding(.leading, 74) }
                    HStack(spacing: 12) {
                        Text(LiveBusLayer.label(approach, now: store.now))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LiveBusSummary.stopsAway(approach)).font(.subheadline.weight(.medium))
                            Text("Here at \(approach.due.clock)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        LiveDot()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 56)
                    .contentShape(.rect)
                    .onTapGesture { scene.frame([approach.bus.coordinate, line.stopCoordinate], margin: 400) }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Shows this bus on the map")
                }
            }
            .surface()
            .transaction { $0.animation = nil }
        }
        Text("Live from TfL. A bus's place is worked out from when it's due at the stops ahead, updated every 30 seconds.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var timetable: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text("Leaving").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(line.departures) { departure in
                    HStack {
                        Text(departure.expected.clock).font(.subheadline.weight(.semibold)).monospacedDigit()
                        if departure.isRealtime { LiveDot() }
                        Spacer()
                        let minutes = Int(departure.expected.timeIntervalSince(context.date) / 60)
                        Text(minutes < 1 ? "Now" : "\(minutes) min").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .surface()
        }
    }
}
