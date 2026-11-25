import SwiftUI

/// Every source's journeys, merged and ranked, filling in as each one answers.
/// The trip itself (from, to, when) is edited in place at the top.
struct ResultsSheet: View {
    @State private var query: JourneyQuery

    init(query: JourneyQuery) { _query = State(initialValue: query) }

    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @Environment(MapScene.self) private var scene
    @Environment(LocationService.self) private var location
    @Environment(DepartureStore.self) private var departures
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model = SearchModel()
    /// The trip as last searched, before Current Location was resolved.
    @State private var searched: JourneyQuery?
    @State private var showMore = false
    @State private var showFilters = false
    @State private var showSources = false
    @State private var editing: Edit?
    @State private var timeSheet: TimeKind?
    /// The time on the wheel, kept here so a fold moving it between sheet and panel doesn't reset it.
    @State private var timeDraft = Date.now
    /// Pages under the top one stay alive; only the top one drives the map.
    @State private var isOnTop = false
    #if DEBUG
    @State private var didDemo = false
    #endif

    enum Edit: Identifiable {
        case origin, destination
        var id: Self { self }
    }

    enum TimeKind: Identifiable {
        case depart, arrive
        var id: Self { self }
    }

    /// On a shallow sheet the trip takes one row so there is room for the best route.
    private var isTight: Bool { router.sheetIsShallow && !typeSize.isAccessibilitySize }

    private var ranked: JourneyRanker.Ranked {
        JourneyRanker.rank(model.journeys, arriveBy: query.time.isArriveBy, sort: settings.sortOrder, filter: settings.routeFilter)
    }

    var body: some View {
        let ranked = ranked
        let reference = reference(ranked)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isTight { compactTripEditor } else { tripEditor }
                controls
                if let first = ranked.top.first {
                    routeLink(first, reference: reference, isLead: true)
                        .surface(highlighted: true)
                } else if ranked.more.isEmpty {
                    statusLine(ranked)
                }
                let notices = notices(ranked)
                if !notices.isEmpty { NoticeList(notices: notices) }
                if ranked.top.count > 1 {
                    routeGroup(ranked.top.dropFirst(), reference: reference)
                }
                appleHintIfQuicker(reference)
                if ranked.onlyBlockedRoutes {
                    Label("All routes go through a reported closure", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                    routeGroup(ranked.more[...], reference: nil)
                } else if !ranked.more.isEmpty {
                    moreSection(ranked.more, reference: reference)
                }
                if ranked.hidden > 0 { hiddenNote(ranked.hidden, all: ranked.top.isEmpty && ranked.more.isEmpty) }
                if ranked.top.isEmpty && ranked.more.isEmpty && ranked.hidden == 0 && !model.isSearching { emptyState }
                if !ranked.top.isEmpty || !ranked.more.isEmpty { statusLine(ranked) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
            .animation(.snappy, value: ranked)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Transit Routes")
        .lowRestBar()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Put away on the cover the column has room for Back alone.
            if !router.columnHoldsOneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Open this trip in") {
                            if let reminder = query.time.handoffTimeReminder { Text(reminder) }
                            ForEach(OpenIn.allCases) { app in
                                // The other app is handed the destination: not one that is
                                // "where you are" from before location was turned off.
                                Button(app.name, systemImage: app.symbol) { app.open(query) }
                                    .disabled(query.destination.isCurrentLocation && location.isDenied)
                            }
                        }
                    } label: {
                        Label("Open in another app", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        // Sheets on a phone. Wide open on a Duo, filters and the time dock on the map half,
        // beside the list they change, and search is a page over the pane.
        .mapPanel(isPresented: $showFilters, id: "filters", height: 400) {
            FilterSheet().presentationDetents([.medium, .large])
        }
        .paneSheet(item: $editing, id: "results-place") { field in
            PlaceSearchView(title: field == .origin ? "From" : "To", allowsCurrentLocation: true, showsTravelTimes: field == .destination) { place in
                if field == .origin { query.origin = place } else { query.destination = place }
            }
        }
        .mapPanel(item: $timeSheet, id: "time", height: 310) { kind in
            TimePickerSheet(kind: kind, date: $timeDraft) { date in
                query.time = kind == .depart ? .departAt(date) : .arriveBy(date)
            }
            .presentationDetents([.medium])
        }
        .refreshable { await search() }
        .task(id: query) { if searched != query { await search() } }
        .onAppear {
            isOnTop = true
            scene.showResults(ranked.mapJourneys)
            router.settle(.medium)
        }
        .onDisappear { isOnTop = false }
        // Wide open the pane has room for the slower routes too, so they show without a tap.
        .onChange(of: router.foldX != nil, initial: true) { _, wide in if wide { showMore = true } }
        .onChange(of: ranked.mapJourneys) { _, journeys in if isOnTop { scene.showResults(journeys) } }
        #if DEBUG
        .onChange(of: model.isSearching) {
            if Demo.opensDetail, !model.isSearching, !didDemo, let first = self.ranked.top.first?.journey {
                didDemo = true
                router.path.append(.journey(first, query))
            }
        }
        #endif
    }

    /// Searches from where you are now when the trip starts (or ends) at Current
    /// Location: the fix saved with the trip may be from before you moved.
    private func search() async {
        searched = query
        let asked = query
        var resolved = query
        if query.origin.isCurrentLocation || query.destination.isCurrentLocation {
            let here = try? await location.current()
            // The trip was changed while this waited for a fix: the newer search is the one that counts.
            guard asked == query else { return }
            if let here {
                if resolved.origin.isCurrentLocation { resolved.origin.coordinate = here }
                if resolved.destination.isCurrentLocation { resolved.destination.coordinate = here }
            } else if location.isDenied {
                // Location turned off: where you were when the trip was saved isn't sent to the
                // planners in its place, and the last search's routes don't stand in for this one's.
                model.clear(for: query)
                return
            }
        }
        model.search(resolved, settings: settings)
    }

    // MARK: Trip

    private var tripEditor: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                placeRow(label: "From", place: query.origin, isStart: true) { editing = .origin }
                Divider().padding(.leading, 44).padding(.trailing, 64)
                placeRow(label: "To", place: query.destination, isStart: false) { editing = .destination }
            }
            swapButton.padding(.trailing, 12)
        }
        .surface()
        .padding(.top, 4)
    }

    private var swapButton: some View {
        Button {
            withAnimation(.snappy) { (query.origin, query.destination) = (query.destination, query.origin) }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Theme.ink.opacity(0.06), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .disabled(query.destination.isCurrentLocation && query.origin.isCurrentLocation)
        .accessibilityLabel("Swap start and destination")
    }

    /// From and to on one row, each still a button. Where both names don't fit whole,
    /// Current Location is "Here" and the rest give way.
    private var compactTripEditor: some View {
        ViewThatFits(in: .horizontal) {
            compactTripRow(whole: true)
            compactTripRow(whole: false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 48)
        .surface()
        .padding(.top, 4)
    }

    private func compactTripRow(whole: Bool) -> some View {
        HStack(spacing: 8) {
            compactPlace(label: "From", place: query.origin, isStart: true, whole: whole) { editing = .origin }
            Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            compactPlace(label: "To", place: query.destination, isStart: false, whole: whole) { editing = .destination }
                .layoutPriority(1)
            Spacer(minLength: 0)
            swapButton
        }
    }

    private func compactPlace(label: String, place: Place, isStart: Bool, whole: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isStart {
                    Circle().fill(Theme.tint).stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                } else {
                    FractalStar(size: 18)
                }
                Text(!whole && place.isCurrentLocation ? "Here" : place.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: whole, vertical: false)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(place.name)")
        .accessibilityHint("Change")
    }

    private func placeRow(label: String, place: Place, isStart: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if isStart {
                        Circle().fill(Theme.tint).stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                    } else {
                        FractalStar(size: 18)
                    }
                }
                .frame(width: 20)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    Text(place.name).font(.body.weight(.medium))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, 68)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(place.name)")
        .accessibilityHint("Change")
    }

    private var controls: some View {
        @Bindable var settings = settings
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { controlButtons(sortOrder: $settings.sortOrder) }
            } else {
                FlowLayout(spacing: 6) { controlButtons(sortOrder: $settings.sortOrder) }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func controlButtons(sortOrder: Binding<SortOrder>) -> some View {
        Menu {
            Button("Leave now", systemImage: "clock") { query.time = .leaveNow }
            Button("Depart at…", systemImage: "arrow.right.circle") { pickTime(.depart) }
            Button("Arrive by…", systemImage: "flag.checkered") { pickTime(.arrive) }
        } label: {
            controlLabel(timeLabel, systemImage: "clock")
        }
        Menu {
            Picker("Sort", selection: sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            controlLabel(sortOrder.wrappedValue.label, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort: \(sortOrder.wrappedValue.label)")
        let active = settings.routeFilter.activeCount
        Button { showFilters = true } label: {
            controlLabel(active > 0 ? "Filters · \(active)" : "Filters", systemImage: "line.3.horizontal.decrease", active: active > 0)
        }
        .accessibilityLabel("Filters")
        .accessibilityValue(active == 0 ? "None active" : "\(active) active")
    }

    private func pickTime(_ kind: TimeKind) {
        timeDraft = query.time == .leaveNow ? .now : query.time.date
        timeSheet = kind
    }

    private func controlLabel(_ title: String, systemImage: String, active: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(active ? Theme.tint : Theme.ink)
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background(active ? Theme.tint.opacity(0.12) : Theme.ink.opacity(0.06), in: .capsule)
            .contentShape(.capsule)
    }

    private var timeLabel: String {
        switch query.time {
        case .leaveNow: "Leave now"
        case .departAt(let date): "Depart \(controlTime(date))"
        case .arriveBy(let date): "Arrive by \(controlTime(date))"
        }
    }

    private func controlTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.clock }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(date.clock)"
    }

    // MARK: Status

    private func statusLine(_ ranked: JourneyRanker.Ranked) -> some View {
        Button { showSources = true } label: {
            HStack(spacing: 10) {
                if model.isSearching {
                    FractalStar(size: 20, lit: ProviderID.allCases.map { provider in
                        if case .done = model.statuses[provider] { true } else { false }
                    })
                }
                Text(summary(ranked))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Label("Sources", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(Theme.tint)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows route sources")
        .popover(isPresented: $showSources) {
            SourcesPanel(statuses: model.statuses, estimate: model.appleEstimate)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func summary(_ ranked: JourneyRanker.Ranked) -> String {
        let routes = ranked.top.count + ranked.more.count
        let found = "\(routes) route\(routes == 1 ? "" : "s")"
        if model.isSearching { return routes == 0 ? "Finding routes…" : "\(found) so far" }
        let failed = model.statuses.values.filter { if case .failed = $0 { true } else { false } }.count
        if failed == 0 { return found }
        return "\(found) · \(failed) source\(failed == 1 ? "" : "s") unavailable"
    }

    /// Everything reported about the lines and stations these routes use, worst first.
    private func notices(_ ranked: JourneyRanker.Ranked) -> [ServiceNotice] {
        var seen = Set<ServiceNotice.DisplayID>()
        var all = (ranked.top + ranked.more).flatMap(\.journey.notices)
        #if DEBUG
        if Demo.addsNotices, !ranked.top.isEmpty { all += Demo.notices }
        #endif
        return all
            .filter { seen.insert($0.displayID).inserted }
            .sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.title < $1.title }
    }

    /// Turned tall on a Duo with the sheet at full height there is room for the best route's
    /// first ride to show what else is leaving, which on a phone takes a tap into the journey.
    /// The best route only: one board as it is shown, kept a minute (`DepartureStore`).
    private var showsLeadBoard: Bool { router.foldY != nil && !router.inTablePose && router.detent == .large }

    private func leadBoard(_ ride: Leg) -> some View {
        DepartureStrip(leg: ride, state: departures.board(ride), linksToBoard: false)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .task { await departures.load(ride) }
    }

    /// What each row's "+3 min" is measured against.
    private func reference(_ ranked: JourneyRanker.Ranked) -> Date? {
        query.time.isArriveBy ? ranked.top.map(\.journey.departure).max() : ranked.top.map(\.journey.arrival).min()
    }

    // MARK: Routes

    private func routeGroup(_ options: ArraySlice<RouteOption>, reference: Date?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().padding(.leading, 16) }
                routeLink(option, reference: reference)
            }
        }
        .surface()
    }

    private func routeLink(_ option: RouteOption, reference: Date?, isLead: Bool = false) -> some View {
        NavigationLink(value: Page.journey(option.journey, query)) {
            VStack(alignment: .leading, spacing: 0) {
                RouteRow(option: option, isLead: isLead, reference: reference, arriveBy: query.time.isArriveBy)
                if isLead, showsLeadBoard, let ride = option.journey.transitLegs.first { leadBoard(ride) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func appleHintIfQuicker(_ reference: Date?) -> some View {
        if let estimate = model.appleEstimate, let reference, !query.time.isArriveBy,
           estimate.arrival < reference.addingTimeInterval(-120) {
            appleHint(estimate)
        }
    }

    /// Only worth a line when Apple's estimate beats every route here.
    private func appleHint(_ estimate: AppleEstimate) -> some View {
        Button {
            // Apple Maps is handed the destination: not one that is "where you are" from before
            // location was turned off.
            guard !(query.destination.isCurrentLocation && location.isDenied) else { return }
            OpenIn.appleMaps.open(query)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Maps · \(estimate.travelTime.minutesText)")
                        .font(.subheadline.weight(.semibold))
                    Text(query.time.handoffTimeReminder ?? "Faster estimate")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tint)
            }
            .padding(14)
            .surface()
        }
        .buttonStyle(.plain)
    }

    private func moreSection(_ more: [RouteOption], reference: Date?) -> some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { showMore.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(showMore ? "Show fewer" : moreLabel(more))
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showMore ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showMore { routeGroup(more[...], reference: reference) }
        }
    }

    private func moreLabel(_ more: [RouteOption]) -> String {
        let blocked = more.filter(\.journey.isBlocked).count
        let routes = "\(more.count) route\(more.count == 1 ? "" : "s")"
        if blocked == 0 { return "\(more.count) slower or longer route\(more.count == 1 ? "" : "s")" }
        return blocked == more.count ? "\(routes) through a closure" : "\(more.count) more routes, \(blocked) through a closure"
    }

    private func hiddenNote(_ count: Int, all: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(all ? "Filters hide every route" : "\(count) route\(count == 1 ? "" : "s") filtered out")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Clear filters") { withAnimation(.snappy) { settings.routeFilter = RouteFilter() } }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            FractalStar(size: 44, lit: [false, false, false, false])
            Text("No routes found").font(.headline)
            OpenInRow(query: query)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

/// One route on the list: how long, which lines, when the first one leaves.
struct RouteRow: View {
    var option: RouteOption
    var isLead: Bool
    /// Earliest arrival on the list (or, arriving by a time, latest departure).
    var reference: Date?
    var arriveBy: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var journey: Journey { option.journey }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    duration.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    times(alignment: .trailing).fixedSize(horizontal: true, vertical: false)
                    routeChevron
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        duration
                        Spacer(minLength: 4)
                        routeChevron
                    }
                    times(alignment: .leading)
                }
            }

            LegStrip(legs: journey.legs)

            metrics

            if let ride = firstRide {
                boarding(ride)
            }

            if let alternateTimes {
                Label("Also leave \(alternateTimes)", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let disruption {
                let minor = journey.worstNotice?.severity == .minor
                Label(disruption, systemImage: minor ? "info.circle" : "exclamationmark.triangle.fill")
                    .font(.footnote.weight(minor ? .regular : .semibold))
                    .foregroundStyle(minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isLead ? 14 : 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var duration: some View {
        Text(journey.duration.minutesText)
            .font(isLead ? .title2.bold() : .title3.weight(.semibold))
            .monospacedDigit()
    }

    private func times(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                if journey.isRealtime { LiveDot() }
                JourneyTimeSpan(journey: journey)
                    .font(.subheadline.weight(.medium))
            }
            if let delta { Text(delta).font(.footnote) }
        }
        .foregroundStyle(.secondary)
    }

    private var routeChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var firstRide: Leg? { journey.legs.first(where: \.mode.isTransit) }
    private var metrics: RouteMetrics { RouteMetrics(journey: journey, providers: option.providers) }

    private var disruption: String? {
        journey.worstNotice?.title ?? (journey.hasDisruption ? "Service disruption" : nil)
    }

    private var alternateTimes: String? {
        guard !option.otherDepartures.isEmpty else { return nil }
        return option.otherDepartures.prefix(3).map(\.clock).joined(separator: " · ")
    }

    private func boarding(_ ride: Leg) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Label("Board \(ride.departure.clock)", systemImage: "location.circle")
                .fontWeight(.semibold)
                .monospacedDigit()
                .layoutPriority(1)
            if let platform = ride.platform { PlatformTag(text: ride.standing(at: platform)) }
            if !ride.fromName.isEmpty {
                Text(ride.fromName)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// How much later than the quickest this gets you there.
    private var delta: String? {
        guard let reference else { return nil }
        let minutes = Int(((arriveBy ? reference.timeIntervalSince(journey.departure) : journey.arrival.timeIntervalSince(reference)) / 60).rounded())
        guard minutes > 0 else { return nil }
        return arriveBy ? "leave \(minutes) min earlier" : "+\(minutes) min"
    }

    private var spoken: String {
        let lines = journey.transitLegs.map { $0.line ?? $0.mode.label }.formatted(.list(type: .and))
        let board = firstRide.map { ride in
            ["Board at \(ride.departure.clock)", ride.platform.map { ride.standing(at: $0) }, ride.fromName].compactMap { $0 }.joined(separator: ", ")
        }
        let providers = option.providers.map(\.name).formatted(.list(type: .and))
        let timeSpan = JourneyTimeSpan(journey: journey)
        let parts: [String?] = [isLead ? "Top route" : nil, journey.duration.minutesText, timeSpan.spoken, delta, lines, metrics.spoken,
                                board, alternateTimes.map { "Other departures \($0)" }, disruption, providers, journey.isRealtime ? "Live times" : nil]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The same route facts in search and in the trip overview.
struct RouteMetrics: View {
    let journey: Journey
    var providers: [ProviderID] = []

    private var changes: String { journey.changes == 0 ? "Direct" : "\(journey.changes) change\(journey.changes == 1 ? "" : "s")" }
    private var walking: String? { journey.walkingTime >= 30 ? "\(journey.walkingTime.minutesText) walk" : nil }

    var spoken: String { [changes, walking, journey.fare].compactMap { $0 }.joined(separator: ", ") }

    var body: some View {
        FlowLayout(spacing: 8) {
            Label(changes, systemImage: journey.changes == 0 ? "arrow.right" : "arrow.left.arrow.right")
            if let walking { Label(walking, systemImage: "figure.walk") }
            if let fare = journey.fare { Label(fare, systemImage: "creditcard") }
            ForEach(providers, id: \.self) { SourceBadge(provider: $0) }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

struct JourneyTimeSpan: View {
    let journey: Journey

    var spoken: String { "Leave \(journey.departure.clock), arrive \(journey.arrival.clock)" }

    var body: some View {
        HStack(spacing: 5) {
            Text(journey.departure.clock)
            Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.secondary)
            Text(journey.arrival.clock)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// What TfL reports wrong on the lines and stations these routes use. A closure
/// says where the routes through it went; the operator's words open on a tap.
struct NoticeList: View {
    var notices: [ServiceNotice]
    @State private var open: Set<ServiceNotice.DisplayID> = []
    @State private var expanded = false

    var body: some View {
        if let worst = notices.first {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(notices, id: \.displayID) { notice in
                        Divider().padding(.leading, 28)
                        row(notice)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    icon(worst)
                    Text(expanded ? "Service alerts" : worst.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if notices.count > 1 {
                        Text("\(notices.count)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .accessibilityLabel("\(notices.count) alerts")
                    }
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .surface()
        }
    }

    private func icon(_ notice: ServiceNotice) -> some View {
        Image(systemName: notice.severity == .minor ? "info.circle" : "exclamationmark.triangle.fill")
            .foregroundStyle(notice.severity == .minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
            .frame(width: 16)
    }

    @ViewBuilder private func row(_ notice: ServiceNotice) -> some View {
        let key = notice.displayID
        let isOpen = open.contains(key)
        if notice.detail.isEmpty {
            noticeRow(notice, isOpen: false)
        } else {
            Button {
                withAnimation(.snappy) { if isOpen { open.remove(key) } else { open.insert(key) } }
            } label: {
                noticeRow(notice, isOpen: isOpen)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the full notice" : "Shows the full notice")
        }
    }

    private func noticeRow(_ notice: ServiceNotice, isOpen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon(notice)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.subheadline.weight(.semibold))
                if isOpen { Text(notice.detail).font(.footnote).foregroundStyle(.secondary) }
                SourceBadge(provider: notice.source)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !notice.detail.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .foregroundStyle(Theme.tint)
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// Pick a time to leave at or arrive by.
private struct TimePickerSheet: View {
    var kind: ResultsSheet.TimeKind
    @Binding var date: Date
    var onDone: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose

    var body: some View {
        NavigationStack {
            DatePicker(kind == .depart ? "Depart at" : "Arrive by", selection: $date, in: Date.now.addingTimeInterval(-3600)...)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding()
                .navigationTitle(kind == .depart ? "Depart at" : "Arrive by")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss(or: paneClose) } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") {
                            onDone(date)
                            dismiss(or: paneClose)
                        }
                    }
                }
        }
    }
}

/// Who answered, who didn't, and Apple's estimate.
struct SourcesPanel: View {
    var statuses: [ProviderID: ProviderStatus]
    var estimate: AppleEstimate?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sources").font(.headline)
            ForEach(ProviderID.allCases, id: \.self) { provider in
                if let status = statuses[provider] {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(provider)).frame(width: 8, height: 8)
                        Text(provider.name).font(.subheadline.weight(.medium))
                        Spacer(minLength: 16)
                        Text(describe(provider, status))
                            .font(.subheadline)
                            .foregroundStyle(style(status))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .foregroundStyle(Theme.ink)
    }

    private func describe(_ provider: ProviderID, _ status: ProviderStatus) -> String {
        switch status {
        case .loading: "Searching…"
        case .done(let count): provider == .apple ? estimate.map { "Estimates \($0.travelTime.minutesText)" } ?? "Done" : "\(count) found"
        case .failed(let reason), .off(let reason): reason
        }
    }

    private func style(_ status: ProviderStatus) -> AnyShapeStyle {
        switch status {
        case .failed: AnyShapeStyle(Theme.warning)
        case .off: AnyShapeStyle(.tertiary)
        default: AnyShapeStyle(.secondary)
        }
    }
}
