import SwiftUI

/// One journey: the whole route on the map, an itinerary with live departure
/// boards at every boarding stop, and Go.
struct JourneySheet: View {
    let journey: Journey
    let query: JourneyQuery

    @Environment(Router.self) private var router
    @Environment(MapScene.self) private var scene
    @Environment(DepartureStore.self) private var departures
    @Environment(LocationService.self) private var location
    @Environment(LiveBusStore.self) private var buses
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var alertDraft: RouteAlert?
    @State private var framedBusFor: UUID?
    @State private var makingAlert = false
    /// Settings opened mid-trip, over Go, which carries on underneath.
    @State private var showSettings = false
    /// Wide open on a Duo: the leg whose departures are on the map half.
    @State private var boardLeg: Leg?
    #if DEBUG
    @State private var didDemo = false
    #endif

    private var trip: LiveTrip? { router.trip?.journey.id == journey.id ? router.trip : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let trip {
                    LiveGuide(trip: trip, onSettings: { showSettings = true }, onEnd: end)
                } else {
                    header
                }
                Itinerary(journey: journey, query: query, trip: trip, boardLeg: $boardLeg)
                if trip == nil {
                    foundBy
                    OpenInRow(query: query)
                }
            }
            .padding(.horizontal, 16)
            // Go has no navigation bar: its own top row sits under the grabber.
            .padding(.top, trip != nil ? 14 : 6)
            .padding(.bottom, 30)
            .animation(.snappy, value: usesColumn)
        }
        .scrollIndicators(.hidden)
        // On the Duo's cover during Go the column beside the sheet holds nothing (Go has no bar),
        // so below the clock the sheet's content runs the whole width.
        .ignoresSafeArea(.container, edges: usesColumn ? .trailing : [])
        .navigationTitle(query.destination.name)
        .lowRestBar {
            // Wide open, put away: Go's own top row is the bar, as the navigation bar is otherwise.
            if let trip {
                LiveGuideHeader(trip: trip, onSettings: { showSettings = true }, onEnd: end)
                    .padding(.horizontal, 16)
            }
        }
        .navigationSubtitle("From \(query.origin.name)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(trip != nil)
        // During Go the header row carries the destination, Settings and End, as Maps' does;
        // a navigation bar above it cost a row the 210 pt rest doesn't have.
        .toolbar(trip != nil ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if trip == nil, AlertStore.shared.isConfigured, hasTfLLines, !router.columnHoldsOneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Alert me about these lines", systemImage: makingAlert ? "ellipsis" : "bell.badge") { makeAlert() }
                        .disabled(makingAlert || !AlertStore.shared.canAddWatch)
                }
            }
        }
        .onAppear {
            if let trip { scene.follow(near: trip.leg.start) } else { scene.showJourney(journey, to: query.destination) }
            #if DEBUG
            if Demo.startsTrip || Demo.offline, !didDemo, router.trip == nil {
                didDemo = true
                start()
            }
            #endif
        }
        .sensoryFeedback(.start, trigger: trip != nil) { _, live in live }
        // A bus ride picked out: once its buses are in, bring the next one into view.
        .onChange(of: buses.approaching.first?.id) { _, id in
            guard trip == nil, id != nil, let focused = scene.focusedLeg, framedBusFor != focused,
                  let leg = journey.legs.first(where: { $0.id == focused }), buses.watch == BusWatch(leg: leg),
                  let next = buses.approaching.first else { return }
            framedBusFor = focused
            scene.frame(leg.path + [next.bus.coordinate])
        }
        // A pushed page on a phone; wide open, the picked leg's departures sit under its
        // map, beside the legs.
        .mapPanel(item: $boardLeg, id: "board", height: 340, sheetWhenFolded: false) { BoardPanel(leg: $0) }
        // Folded or turned tall the board is a page, as on a phone: keep it in view as one.
        .onChange(of: router.foldX == nil) { _, notWide in
            guard notWide, let leg = boardLeg else { return }
            boardLeg = nil
            router.path.append(.board(leg))
        }
        // Its own id: Home, still alive under the stack, has its own Settings sheet.
        .paneSheet(isPresented: $showSettings, id: "go-settings") { SettingsView() }
        .paneSheet(item: $alertDraft, id: "journey-alert") { draft in
            NavigationStack { AlertEditor(alert: draft, isNew: true) }
        }
    }

    /// During Go on the Duo's cover, below full height: the column beside the sheet is free.
    /// At full height the sheet's top reaches the camera and the clock, so it stays clear.
    private var usesColumn: Bool { trip != nil && router.barIsBeside && router.detent != .large }

    private var hasTfLLines: Bool {
        journey.transitLegs.contains { [.tube, .dlr, .elizabeth, .overground, .tram, .rail].contains($0.mode.refined(line: $0.line, agency: nil)) }
    }

    /// The journey's TfL lines, each from where you get on to where you get off, around when you'd travel.
    private func makeAlert() {
        makingAlert = true
        Task {
            alertDraft = try? await TfLLines.draft(for: journey)
            makingAlert = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: router.foldY != nil ? .center : .firstTextBaseline, spacing: 12) {
                    Text(journey.duration.minutesText)
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                    // Turned tall on a Duo the sheet rests at 210 pt under a tall map: the whole
                    // trip at a glance beside its time, in room the phone doesn't have, with Go
                    // still in view below.
                    if router.foldY != nil { LegStrip(legs: journey.legs) }
                    Spacer(minLength: 0)
                    if let fare = journey.fare { Text(fare).font(.title3).foregroundStyle(.secondary) }
                }
                Text(summary)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Label(leaveText(context.date), systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(leaveIsUrgent(context.date) ? Theme.warning : Theme.ink)
                }
                .padding(.top, 2)
            }
            .accessibilityElement(children: .combine)

            // Side by side until the text is too big for it.
            let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            actions {
                Button(action: start) {
                    Label("Go", systemImage: "location.north.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.tint)
                .accessibilityHint("Follows you along the journey with live walking directions")

                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.tint)
            }
        }
    }

    private var summary: String {
        let changes = journey.changes == 0 ? "Direct" : "\(journey.changes) change\(journey.changes == 1 ? "" : "s")"
        return "\(journey.departure.clock) – \(journey.arrival.clock) · \(changes) · \(Int((journey.walkingTime / 60).rounded())) min walk"
    }

    private func leaveText(_ now: Date) -> String {
        let minutes = Int((journey.departure.timeIntervalSince(now) / 60).rounded(.down))
        if minutes >= 60 { return "Leave at \(journey.departure.clock)" }
        if minutes >= 1 { return "Leave in \(minutes) min" }
        if minutes >= -1 { return "Leave now" }
        return "Was due to leave at \(journey.departure.clock)"
    }

    private func leaveIsUrgent(_ now: Date) -> Bool {
        let seconds = journey.departure.timeIntervalSince(now)
        return seconds < 120 && seconds > -600
    }

    private var shareText: String {
        let lines = journey.transitLegs.compactMap { $0.line.map(LinePill.shortName) }
        let how = lines.isEmpty ? "walking" : "taking the \(lines.formatted(.list(type: .and)))"
        return "On my way to \(query.destination.name), \(how). Arriving about \(journey.arrival.clock)."
    }

    private var foundBy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Found by").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(journey.providers, id: \.self) { provider in
                HStack(spacing: 8) {
                    Circle().fill(Theme.color(provider)).frame(width: 7, height: 7)
                    Text(provider.name).font(.subheadline.weight(.medium))
                    Text(journey.sources.filter { $0.provider == provider }.map(\.variant).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func start() {
        #if DEBUG
        // `-demoReplan`: canned boards and a canned planner answer, nothing fetched, early onto the Bakerloo.
        let trip = Demo.offline
            ? LiveTrip(journey: journey, query: query, location: location, departures: departures, buses: buses,
                       boards: { ReplanDemo.boards[$0.id] }, loadBoard: { _ in },
                       search: ReplanDemo.search, isOnline: { true }, store: .shared)
            : LiveTrip(journey: journey, query: query, location: location, departures: departures, buses: buses,
                       search: ReplanSearch.live(settings: settings), store: .shared)
        #else
        let trip = LiveTrip(journey: journey, query: query, location: location, departures: departures, buses: buses,
                            search: ReplanSearch.live(settings: settings), store: .shared)
        #endif
        router.trip = trip
        trip.start()
        #if DEBUG
        if let leg = Demo.startLeg { trip.select(leg) }
        if Demo.offline { trip.take(.boarded(journey.legs[1])) }
        #endif
        // Go follows you on the map half; a board left open from planning would sit over it.
        boardLeg = nil
        router.settle(router.goRest)
        // After the sheet has shrunk and the banner is in: MapKit drops a follow
        // that starts while the map's insets are still moving.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            scene.follow(near: trip.leg.start)
        }
    }

    private func end() {
        router.endTrip()
        scene.showJourney(journey, to: query.destination)
    }
}

/// The journey leg by leg, on a timeline: walks with turn-by-turn on demand,
/// rides with their stops, platform and a live board of what else is leaving.
struct Itinerary: View {
    let journey: Journey
    let query: JourneyQuery
    var trip: LiveTrip?
    @Binding var boardLeg: Leg?

    @Environment(MapScene.self) private var scene
    @Environment(Router.self) private var router

    /// During Go, the journey's times as the trip is really going.
    private var timed: Journey { trip?.timeline.journey ?? journey }
    /// During Go, the trip's legs: after a switch, the new way.
    private var legs: Journey { trip?.journey ?? journey }

    var body: some View {
        let journey = legs
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                LegRow(leg: leg, index: index, isLast: index == journey.legs.count - 1,
                       destination: query.destination.name, origin: query.origin.name,
                       departure: timed.legs[index].departure, arrival: timed.legs[index].arrival,
                       tripBoard: trip.flatMap { leg.mode.isTransit ? $0.board(for: leg) : nil },
                       platform: trip?.platform(for: leg) ?? leg.platform,
                       state: state(index), reachable: reachable(index),
                       isAboard: trip.map { $0.legIndex == index && leg.mode.isTransit && !$0.isWaiting && !$0.missedRide } ?? false,
                       atStop: index > 0 ? timed.legs[index - 1].arrival : timed.legs[index].departure,
                       notices: journey.notices.filter { $0.leg == leg.id },
                       onBoard: { boardLeg = leg }) {
                    if let trip { trip.select(index) } else {
                        scene.focus(leg)
                        router.settle(.medium)
                        if router.isPane { boardLeg = leg.mode.isTransit ? leg : nil }
                    }
                }
            }
        }
        .padding(16)
        .surface()
    }

    /// For a change, you can't be at the stop before the ride before gets in.
    private func reachable(_ index: Int) -> Date? {
        let timed = timed
        guard let previous = timed.legs[..<index].lastIndex(where: \.mode.isTransit) else { return nil }
        let walk = timed.legs[previous + 1 ..< index].reduce(0) { $0 + $1.duration }
        return timed.legs[previous].arrival.addingTimeInterval(walk)
    }

    private func state(_ index: Int) -> LegRow.State {
        guard let trip else { return .planned }
        return index < trip.legIndex ? .done : index == trip.legIndex ? .current : .planned
    }
}

private struct LegRow: View {
    enum State { case planned, current, done }

    var leg: Leg
    var index: Int
    var isLast: Bool
    var destination: String
    var origin: String
    /// When it leaves and gets in: the plan's, or during Go the trip's as it's going.
    var departure: Date
    var arrival: Date
    /// During Go, the ride's board with the departure you're on (or will now catch) as yours.
    var tripBoard: DepartureBoard?
    /// Where it leaves from: during Go, the platform of the train you'll catch.
    var platform: String?
    var state: State
    var reachable: Date?
    /// During Go, on this ride now: its board would only say your own train has gone.
    var isAboard = false
    /// When you get to the stop, so waiting counts against the ride.
    var atStop: Date
    var notices: [ServiceNotice]
    /// Wide open on a Duo: show this ride's departures on the map half.
    var onBoard: () -> Void
    var onSelect: () -> Void

    @Environment(DepartureStore.self) private var departures
    @Environment(LiveBusStore.self) private var buses
    @Environment(MapScene.self) private var scene
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @SwiftUI.State private var showDirections = false
    @SwiftUI.State private var showStops = false
    @SwiftUI.State private var directions: Loadable<WalkRoute>?
    /// Walking the same stretch as a bus, for buses that crawl.
    @SwiftUI.State private var walkInstead: TimeInterval?

    private var color: Color {
        guard leg.mode.isTransit else { return Theme.ink.opacity(0.25) }
        return Theme.line(leg.lineColor)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                Text(departure.clock)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(width: 46, alignment: .leading)
                    .padding(.top, 1)
            }
            rail
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(typeSize.isAccessibilitySize ? "\(departure.clock) \(fromName)" : fromName)
                                .font(.subheadline.weight(.semibold))
                            if state == .current {
                                Text("Now").font(.caption.weight(.bold)).foregroundStyle(Theme.tint)
                            }
                        }
                        if leg.mode.isTransit { transitTitle } else { walkTitle }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(state == .planned ? "Shows this part on the map" : "")

                if leg.mode.isTransit { transitDetail } else { walkDetail }

                if isLast {
                    HStack {
                        Text(destination).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(arrival.clock).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, isLast ? 0 : 20)
            Spacer(minLength: 0)
        }
        .opacity(state == .done ? 0.45 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fromName: String {
        if index == 0, !leg.mode.isTransit { return origin }
        return leg.fromName.isEmpty ? "Start" : leg.fromName
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(state == .current ? Theme.tint : Theme.surface)
                .stroke(leg.mode.isTransit ? color : Theme.ink.opacity(0.35), lineWidth: 2.5)
                .frame(width: 13, height: 13)
            if leg.mode.isTransit {
                Rectangle().fill(color).frame(width: 5).frame(maxHeight: .infinity)
            } else {
                DottedLine().stroke(Theme.ink.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.5, 6]))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
            }
            if isLast { FractalStar(size: 18) }
        }
        .frame(width: 18)
    }

    // MARK: Walks

    private var walkTitle: some View {
        HStack(spacing: 8) {
            Label("Walk \(leg.duration.minutesText)", systemImage: "figure.walk")
            if let metres = leg.distanceMeters, metres > 0 { Text(LiveTrip.distanceText(metres)) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var walkDetail: some View {
        if leg.start != nil, leg.end != nil, leg.duration >= 60 {
            Button {
                withAnimation(.snappy) { showDirections.toggle() }
            } label: {
                Label(showDirections ? "Hide directions" : "Directions", systemImage: "arrow.turn.up.right")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .task(id: showDirections) {
                guard showDirections, directions?.value == nil, let start = leg.start, let end = leg.end else { return }
                directions = .loading
                do { directions = .loaded(try await WalkRouter.route(from: start, to: end)) } catch {
                    directions = .failed("No walking directions here")
                }
            }
            if showDirections { WalkSteps(state: directions) }
        }
    }

    // MARK: Rides

    @ViewBuilder private var transitTitle: some View {
        let direction = leg.headsign.map { $0.lowercased().hasPrefix("via") ? $0 : "towards \($0)" }
        Group {
            if router.isNarrow {
                // Under 400 pt the line's name stays whole, and the direction goes under it if
                // the two don't fit on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        LinePill(leg: leg, compact: true).fixedSize()
                        if let direction { Text(direction).lineLimit(1).fixedSize() }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        LinePill(leg: leg, compact: true).fixedSize()
                        if let direction { Text(direction).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    LinePill(leg: leg, compact: true)
                    if let direction { Text(direction).lineLimit(1) }
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// A bus can take longer than walking, once you've waited for it. Walking time
    /// is Apple's, along streets, between the stops.
    @ViewBuilder private var walkAlternative: some View {
        if let walk = walkInstead {
            let bus = leg.arrival.timeIntervalSince(min(atStop, leg.departure))
            if walk <= bus + 120 {
                Label(walk < bus - 120 ? "Walking is quicker: \(walk.minutesText)" : "Walking is about as quick: \(walk.minutesText)",
                      systemImage: "figure.walk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
            } else {
                Label("Or walk it in \(walk.minutesText)", systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadWalkInstead() async {
        guard [.bus, .coach].contains(leg.mode), walkInstead == nil, let start = leg.start, let end = leg.end,
              start.distance(to: end) < 8_000 else { return }
        walkInstead = try? await WalkRouter.walkingTime(from: start, to: end)
    }

    @ViewBuilder private var transitDetail: some View {
        ForEach(notices, id: \.displayID) { notice in
            AlertLine(alert: ServiceAlert(header: notice.title, detail: notice.detail.isEmpty ? nil : notice.detail),
                      minor: notice.severity == .minor)
        }
        let info = [leg.stopCount.map { "\($0) stop\($0 == 1 ? "" : "s")" }, leg.duration.minutesText].compactMap { $0 }
        Button {
            if !leg.intermediateStops.isEmpty { withAnimation(.snappy) { showStops.toggle() } }
        } label: {
            HStack(spacing: 6) {
                // The platform up front, in ink: it decides where you stand.
                if let platform, state != .done { PlatformTag(text: leg.standing(at: platform)) }
                Text(info.joined(separator: " · "))
                if !leg.intermediateStops.isEmpty {
                    Image(systemName: "chevron.down").imageScale(.small).rotationEffect(.degrees(showStops ? 180 : 0))
                }
                if leg.isRealtime { LiveDot() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(leg.intermediateStops.isEmpty)
        .task(id: leg.id) { await loadWalkInstead() }
        walkAlternative
        // During Go the guide above says this, for the ride that matters.
        if state != .done, router.trip == nil, let watch = BusWatch(leg: leg) {
            if buses.watch == watch {
                LiveBusSummary(watch: watch)
            } else {
                Button {
                    scene.focus(leg)
                    router.settle(.medium)
                } label: {
                    Label("Where are the buses?", systemImage: "bus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows the buses on this route live on the map")
            }
        }
        if showStops {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(leg.intermediateStops.enumerated()), id: \.offset) { _, stop in
                    Text(stop).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 2)
        }
        if state != .done, !isAboard {
            Group {
                if router.isPane {
                    Button(action: onBoard) { DepartureStrip(leg: leg, state: tripBoard.map { .loaded($0) } ?? departures.board(leg), reachable: reachable) }
                } else {
                    NavigationLink(value: Page.board(leg)) {
                        DepartureStrip(leg: leg, state: tripBoard.map { .loaded($0) } ?? departures.board(leg), reachable: reachable)
                    }
                }
            }
            .buttonStyle(.plain)
            .task { await departures.load(leg) }
            // The line's status, unless TfL's notice above already says it.
            if notices.isEmpty, let alert = departures.board(leg)?.value?.alerts.first {
                AlertLine(alert: alert)
            }
        }
    }
}

/// "Platform 2" or "Stop G", set apart from the grey detail beside it.
struct PlatformTag: View {
    var text: String

    var body: some View {
        Text(text.prefix(1).uppercased() + text.dropFirst())
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.ink.opacity(0.08), in: .capsule)
            .fixedSize()
    }
}

private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 2))
        return p
    }
}

/// MapKit's turn-by-turn for a walk.
struct WalkSteps: View {
    var state: Loadable<WalkRoute>?

    var body: some View {
        switch state {
        case .loaded(let route):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(route.steps.enumerated()).filter { !$0.element.instruction.isEmpty }, id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Maneuver.symbol(step.instruction))
                            .frame(width: 18)
                            .foregroundStyle(Theme.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.instruction).font(.footnote)
                            if step.distance > 0 {
                                Text(LiveTrip.distanceText(step.distance)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .loading, nil:
            ProgressView().controlSize(.small)
        }
    }
}

/// An operator's status line ("Minor delays"), opening to the full message.
struct AlertLine: View {
    var alert: ServiceAlert
    /// Worth knowing rather than a warning.
    var minor = false
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: minor ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.header).font(.caption.weight(.semibold))
                    if expanded, let detail = alert.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "" : "Shows the full message")
    }
}

/// Maps an instruction to an arrow.
enum Maneuver {
    static func symbol(_ instruction: String?) -> String {
        let text = instruction?.lowercased() ?? ""
        if text.contains("destination") || text.contains("arrive") { return "mappin.and.ellipse" }
        if text.contains("u-turn") || text.contains("turn around") { return "arrow.uturn.down" }
        if text.contains("roundabout") { return "arrow.triangle.turn.up.right.circle" }
        if text.contains("slight left") || text.contains("bear left") || text.contains("keep left") { return "arrow.up.left" }
        if text.contains("slight right") || text.contains("bear right") || text.contains("keep right") { return "arrow.up.right" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("stairs") || text.contains("steps") { return "figure.stairs" }
        return "arrow.up"
    }
}
