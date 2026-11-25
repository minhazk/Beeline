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
            VStack(alignment: .leading, spacing: 14) {
                if let trip {
                    LiveGuide(trip: trip, onSettings: { showSettings = true }, onEnd: end)
                } else {
                    header
                }
                Itinerary(journey: journey, query: query, trip: trip, boardLeg: $boardLeg)
                if trip == nil {
                    if !journey.providers.isEmpty { foundBy }
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
            if trip == nil, hasTfLLines, !router.columnHoldsOneButton {
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        duration.fixedSize()
                        Spacer(minLength: 0)
                        timing(alignment: .trailing).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        duration
                        timing(alignment: .leading)
                    }
                }
                RouteMetrics(journey: journey)
            }
            .accessibilityElement(children: .combine)

            // Side by side until the text is too big for it.
            let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            actions {
                Button(action: start) {
                    Label("Go", systemImage: "location.north.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.tint)
                .accessibilityHint("Follows you along the journey with live walking directions")

                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.tint)
            }
            if !router.sheetIsShallow || router.foldY != nil { LegStrip(legs: journey.legs) }
        }
    }

    private var duration: some View {
        Text(journey.duration.minutesText)
            .font(router.sheetIsShallow ? .title2.bold() : .largeTitle.bold())
            .monospacedDigit()
    }

    private func timing(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 6) {
                if journey.isRealtime { LiveDot() }
                JourneyTimeSpan(journey: journey)
                    .font(.subheadline.weight(.semibold))
            }
            TimelineView(.periodic(from: .now, by: 20)) { context in
                Label(leaveText(context.date), systemImage: "clock")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(leaveIsUrgent(context.date) ? Theme.warning : Color.secondary)
            }
        }
    }

    private func leaveText(_ now: Date) -> String {
        let minutes = Int((journey.departure.timeIntervalSince(now) / 60).rounded(.down))
        if minutes >= 60 {
            if Calendar.current.isDateInToday(journey.departure) { return "Leaves today" }
            return "Leaves \(journey.departure.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if minutes >= 1 { return "Leave in \(minutes) min" }
        if minutes >= -1 { return "Leave now" }
        return "Past departure time"
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
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(journey.providers, id: \.self) { provider in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name).font(.subheadline.weight(.medium))
                            Text(journey.sources.filter { $0.provider == provider }.map(\.variant).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Circle().fill(Theme.color(provider)).frame(width: 7, height: 7)
                    }
                }
            }
            .padding(.bottom, 10)
        } label: {
            HStack(spacing: 8) {
                Text("Route sources").font(.footnote.weight(.semibold))
                if !typeSize.isAccessibilitySize {
                    ForEach(journey.providers, id: \.self) { SourceBadge(provider: $0) }
                }
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .surface()
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
        .padding(12)
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
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 46
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
        HStack(alignment: .top, spacing: 8) {
            if !typeSize.isAccessibilitySize {
                Text(departure.clock)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(width: timeWidth, alignment: .leading)
                    .padding(.top, 1)
            }
            rail
            VStack(alignment: .leading, spacing: 6) {
                legHeading
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
            .padding(.bottom, isLast ? 0 : 16)
        }
        .opacity(state == .done ? 0.45 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var legHeading: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(typeSize.isAccessibilitySize ? "\(departure.clock) \(fromName)" : fromName)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if state == .current {
                            Text("Now").font(.caption.weight(.bold)).foregroundStyle(Theme.tint)
                        }
                    }
                    if leg.mode.isTransit { transitTitle } else { walkTitle }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(router.trip == nil ? "Shows this leg on the map" : "Selects this leg")
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
        FlowLayout(spacing: 8) {
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
                Label(showDirections ? "Hide directions" : "Walking directions", systemImage: "arrow.turn.up.right")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                LinePill(leg: leg, compact: true).fixedSize()
                if let direction { Text(direction).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 3) {
                LinePill(leg: leg, compact: true)
                if let direction {
                    Text(direction).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
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
                Label(walk < bus - 120 ? "Walk \(walk.minutesText) · quicker" : "Walk \(walk.minutesText) · similar time",
                      systemImage: "figure.walk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
            } else {
                Label("Or walk \(walk.minutesText)", systemImage: "figure.walk")
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
        rideFacts.task(id: leg.id) { await loadWalkInstead() }
        if showStops {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(leg.intermediateStops.enumerated()), id: \.offset) { _, stop in
                    Label(stop, systemImage: "circle")
                        .imageScale(.small)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        ForEach(notices, id: \.displayID) { notice in
            AlertLine(alert: ServiceAlert(header: notice.title, detail: notice.detail.isEmpty ? nil : notice.detail),
                      minor: notice.severity == .minor)
        }
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
                    Label("Live buses", systemImage: "bus")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows the buses on this route live on the map")
            }
        }
        if state != .done, !isAboard {
            Group {
                if router.isPane {
                    Button(action: onBoard) { departurePreview }
                } else {
                    NavigationLink(value: Page.board(leg)) {
                        departurePreview
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

    private var rideFacts: some View {
        FlowLayout(spacing: 8) {
            if let platform, state != .done { PlatformTag(text: leg.standing(at: platform)) }
            Text(leg.duration.minutesText).monospacedDigit()
            if leg.isRealtime { LiveDot() }
            let stopCount = leg.stopCount.map { "\($0) stop\($0 == 1 ? "" : "s")" }
            if leg.intermediateStops.isEmpty {
                if let stopCount { Text(stopCount) }
            } else {
                Button {
                    withAnimation(.snappy) { showStops.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(stopCount ?? "Stops")
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showStops ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(showStops ? "Hides intermediate stops" : "Shows intermediate stops")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var departurePreview: some View {
        DepartureStrip(leg: leg, state: tripBoard.map { .loaded($0) } ?? departures.board(leg), reachable: reachable)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Theme.ink.opacity(0.045), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
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
        if let detail = alert.detail, !detail.isEmpty {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    message(detail: expanded ? detail : nil)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.tint)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the full message" : "Shows the full message")
        } else {
            message(detail: nil)
        }
    }

    private func message(detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: minor ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                .accessibilityLabel(minor ? "Service information" : "Service warning")
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.header).fontWeight(.semibold)
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .multilineTextAlignment(.leading)
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
