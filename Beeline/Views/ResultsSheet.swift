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
            VStack(alignment: .leading, spacing: 12) {
                if isTight { compactTripEditor } else { tripEditor }
                controls
                if ranked.top.isEmpty { statusLine(ranked) }
                let notices = notices(ranked)
                if !notices.isEmpty { NoticeList(notices: notices) }
                if !ranked.top.isEmpty {
                    routeGroup(ranked.top, reference: reference, leadFirst: true)
                    statusLine(ranked)
                }
                appleHintIfQuicker(reference)
                if ranked.onlyBlockedRoutes {
                    Label("All routes go through a reported closure", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                    routeGroup(ranked.more, reference: nil, leadFirst: false)
                } else if !ranked.more.isEmpty {
                    moreSection(ranked.more, reference: reference)
                }
                if ranked.hidden > 0 { hiddenNote(ranked.hidden, all: ranked.top.isEmpty && ranked.more.isEmpty) }
                if ranked.top.isEmpty && ranked.more.isEmpty && ranked.hidden == 0 && !model.isSearching { emptyState }
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
                                Button(app.name, systemImage: app.symbol) { app.open(query) }
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
        var resolved = query
        if query.origin.isCurrentLocation || query.destination.isCurrentLocation, let here = try? await location.current() {
            if resolved.origin.isCurrentLocation { resolved.origin.coordinate = here }
            if resolved.destination.isCurrentLocation { resolved.destination.coordinate = here }
        }
        model.search(resolved, settings: settings)
    }

    // MARK: Trip

    private var tripEditor: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                placeRow(label: "From", place: query.origin, isStart: true) { editing = .origin }
                Divider().padding(.leading, 44)
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
            Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(Theme.ink)
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
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(place.name)")
        .accessibilityHint("Change")
    }

    private var controls: some View {
        @Bindable var settings = settings
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controlButtons(sortOrder: $settings.sortOrder) }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) { controlButtons(sortOrder: $settings.sortOrder) }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Theme.ink)
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
            controlLabel(active > 0 ? "Filters · \(active)" : "Filters", systemImage: "line.3.horizontal.decrease")
        }
        .tint(active > 0 ? Theme.tint : Theme.ink)
    }

    private func pickTime(_ kind: TimeKind) {
        timeDraft = query.time == .leaveNow ? .now : query.time.date
        timeSheet = kind
    }

    private func controlLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
    }

    private var timeLabel: String {
        switch query.time {
        case .leaveNow: "Leave now"
        case .departAt(let d): "Depart \(d.clock)"
        case .arriveBy(let d): "Arrive by \(d.clock)"
        }
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
                Image(systemName: "info.circle").font(.subheadline).foregroundStyle(Theme.tint)
                    .accessibilityHidden(true)
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
        let asking = ProviderID.allCases.filter { model.statuses[$0] == .loading }.map(\.name)
        if !asking.isEmpty {
            return (routes > 0 ? "\(found) so far · " : "") + "asking \(asking.formatted(.list(type: .and)))"
        }
        let answered = ProviderID.allCases.filter { provider in
            if provider != .apple, case .done = model.statuses[provider] { true } else { false }
        }
        let failed = ProviderID.allCases.filter { provider in
            if case .failed = model.statuses[provider] { true } else { false }
        }
        var text = answered.isEmpty ? "No source answered" : "\(found) from \(answered.map(\.name).formatted(.list(type: .and)))"
        if !failed.isEmpty { text += " · \(failed.map(\.name).formatted(.list(type: .and))) didn't answer" }
        return text
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

    private func routeGroup(_ options: [RouteOption], reference: Date?, leadFirst: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().padding(.leading, 16) }
                NavigationLink(value: Page.journey(option.journey, query)) {
                    VStack(alignment: .leading, spacing: 0) {
                        RouteRow(option: option, isLead: leadFirst && index == 0, reference: reference, arriveBy: query.time.isArriveBy)
                        if leadFirst, index == 0, showsLeadBoard, let ride = option.journey.transitLegs.first {
                            leadBoard(ride)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .surface()
    }

    @ViewBuilder private func appleHintIfQuicker(_ reference: Date?) -> some View {
        if let estimate = model.appleEstimate, let reference, !query.time.isArriveBy,
           estimate.arrival < reference.addingTimeInterval(-120) {
            appleHint(estimate)
        }
    }

    /// Only worth a line when Apple's estimate beats every route here.
    private func appleHint(_ estimate: AppleEstimate) -> some View {
        Button { OpenIn.appleMaps.open(query) } label: {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Maps estimates \(estimate.travelTime.minutesText)")
                        .font(.subheadline.weight(.semibold))
                    Text(query.time.handoffTimeReminder ?? "Quicker than anything here. Open it to see Apple's route.")
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
            if showMore { routeGroup(more, reference: reference, leadFirst: false) }
        }
    }

    private func moreLabel(_ more: [RouteOption]) -> String {
        let blocked = more.filter(\.journey.isBlocked).count
        let routes = "\(more.count) route\(more.count == 1 ? "" : "s")"
        if blocked == 0 { return "\(more.count) slower or longer route\(more.count == 1 ? "" : "s")" }
        return blocked == more.count ? "\(routes) through a closure" : "\(more.count) more routes, \(blocked) through a closure"
    }

    private func hiddenNote(_ count: Int, all: Bool) -> some View {
        HStack {
            Text(all ? "Every route is hidden by your filters" : "\(count) route\(count == 1 ? "" : "s") hidden by your filters")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clear filters") { withAnimation(.snappy) { settings.routeFilter = RouteFilter() } }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            FractalStar(size: 44, lit: [false, false, false, false])
            Text("No routes found").font(.headline)
            Text("None of the sources came back with a journey. Try another app from the menu above, or check Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    duration.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    times.fixedSize(horizontal: true, vertical: false)
                    routeChevron
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        duration
                        Spacer(minLength: 4)
                        routeChevron
                    }
                    times
                }
            }

            LegStrip(legs: journey.legs)

            if let notice = journey.worstNotice {
                Label(notice.title, systemImage: notice.severity == .minor ? "info.circle" : "exclamationmark.triangle.fill")
                    .font(.footnote.weight(notice.severity == .closed ? .semibold : .regular))
                    .foregroundStyle(notice.severity == .minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }

            if let boarding {
                Text(boarding).font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }

            HStack(spacing: 6) {
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if journey.hasDisruption && journey.notices.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                        .accessibilityLabel("Disruption")
                }
                Spacer(minLength: 8)
                if !typeSize.isAccessibilitySize { sourceBadges }
            }
            if typeSize.isAccessibilitySize { sourceBadges }

            if !option.otherDepartures.isEmpty {
                Text("Or leave at \(option.otherDepartures.prefix(3).map(\.clock).formatted(.list(type: .or)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var duration: some View {
        Text(journey.duration.minutesText)
            .font(isLead ? .title2.bold() : .title3.weight(.semibold))
            .monospacedDigit()
    }

    private var times: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if journey.isRealtime { LiveDot() }
                Text("\(journey.departure.clock) – \(journey.arrival.clock)")
                    .font(.subheadline.monospacedDigit())
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

    private var sourceBadges: some View {
        FlowLayout(spacing: 4) {
            ForEach(option.providers, id: \.self) { SourceBadge(provider: $0) }
        }
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
    }

    /// When and where the first ride leaves.
    private var boarding: String? {
        guard let ride = journey.transitLegs.first else { return nil }
        // The platform before the station's name, which is what gives way when the row is narrow.
        return [ride.departure.clock, ride.platform.map { ride.standing(at: $0) }, ride.fromName].compactMap { $0 }.joined(separator: " · ")
    }

    /// How much later than the quickest this gets you there.
    private var delta: String? {
        guard let reference else { return nil }
        let minutes = Int(((arriveBy ? reference.timeIntervalSince(journey.departure) : journey.arrival.timeIntervalSince(reference)) / 60).rounded())
        guard minutes > 0 else { return nil }
        return arriveBy ? "leave \(minutes) min earlier" : "+\(minutes) min"
    }

    private var details: String {
        var parts = [journey.changes == 0 ? "Direct" : journey.changes == 1 ? "1 change" : "\(journey.changes) changes"]
        let walk = Int((journey.walkingTime / 60).rounded())
        if walk > 0 { parts.append("\(walk) min walk") }
        if let fare = journey.fare { parts.append(fare) }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        let lines = journey.transitLegs.compactMap(\.line).formatted(.list(type: .and))
        return [isLead ? "Best route" : nil, journey.worstNotice?.title, journey.duration.minutesText, "leave \(journey.departure.clock), arrive \(journey.arrival.clock)",
                delta, lines, boarding, details, option.providers.map(\.name).formatted(.list(type: .and)), journey.isRealtime ? "live times" : nil]
            .compactMap { $0 }.joined(separator: ", ")
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

    private func row(_ notice: ServiceNotice) -> some View {
        let key = notice.displayID
        let expanded = open.contains(key)
        return Button {
            withAnimation(.snappy) { if expanded { open.remove(key) } else { open.insert(key) } }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                icon(notice)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(notice.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        SourceBadge(provider: notice.source)
                    }
                    if notice.severity == .closed {
                        Text("Check this closure before travelling.").font(.footnote).foregroundStyle(Theme.warning)
                    }
                    if !notice.detail.isEmpty {
                        Text(notice.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .accessibilityHint(expanded ? "Shows less" : "Shows TfL's full notice")
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
            Text("A route several sources found shows once, with each one's badge. The star's points fill in as Google, TfL, Transitous and Apple answer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
