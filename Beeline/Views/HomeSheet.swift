import SwiftUI

/// Home: where to, your saved places, and what's leaving near you right now.
struct HomeSheet: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlaceStore.self) private var places
    @Environment(LocationService.self) private var location
    @Environment(DepartureStore.self) private var departures
    @Environment(Router.self) private var router
    @Environment(MapScene.self) private var scene
    @Environment(AlertStore.self) private var alerts

    @State private var picking: Picking?
    @State private var showSettings = false
    @ScaledMetric(relativeTo: .body) private var shortcutSize: CGFloat = 76
    @State private var offersSetup = false
    @State private var showSetup = false
    @State private var tookFirstRunTurn = false
    @State private var stranded: Place?
    @State private var didDemo = false

    enum Picking: Identifiable {
        case destination, home, work, favorite
        case origin(for: Place)

        var id: String {
            switch self {
            case .destination: "destination"
            case .home: "home"
            case .work: "work"
            case .favorite: "favorite"
            case .origin(let place): "origin-\(place.id)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                searchRow
                savedPlaces
                yourLines
                if places.recents.isEmpty { exampleJourney } else { recents }
                nearby
                if offersSetup {
                    Button("Set up optional services", systemImage: "gearshape") { showSetup = true }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .lowRestBar { searchRow.padding(.horizontal, 16) }
        .toolbar(router.barIsBeside ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            // Put away, Settings is in the bar, on the field's line.
            if router.barIsBeside, router.detent != Router.low {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
        }
        .onAppear {
            router.pageAppeared()
            // Under a page already (a trip picked up at launch): that page has the map.
            if !tookFirstRunTurn {
                if router.path.isEmpty, router.foldX == nil, router.foldY == nil, !router.isShort {
                    router.settle(.medium)
                }
                offersSetup = firstRunTurn()
                #if DEBUG
                showSetup = ProcessInfo.processInfo.arguments.contains("-setup")
                #endif
                tookFirstRunTurn = true
            }
            scene.mayUseLocation = !showSetup
            if router.path.isEmpty { scene.showHome() }
            if !showSetup { location.requestPermission() }
            #if DEBUG
            if Demo.isOn, !didDemo {
                didDemo = true
                // After the sheet has finished presenting, or the push can be dropped.
                Task {
                    // Tried again while the path is still empty: a push during presentation is dropped.
                    for _ in 0..<4 where router.path.isEmpty {
                        try? await Task.sleep(for: .milliseconds(1500))
                        if router.path.isEmpty, Demo.offline {
                            router.path.append(.journey(ReplanDemo.journey, ReplanDemo.query))
                        } else if router.path.isEmpty {
                            router.path.append(.results(JourneyQuery(origin: Demo.origin, destination: Demo.destination, time: .leaveNow)))
                        }
                    }
                }
            }
            #endif
        }
        .task(id: nearbyIsVisible) {
            guard nearbyIsVisible else { return }
            while !Task.isCancelled {
                await refreshNearby()
                do { try await Task.sleep(for: departures.nearbyRefreshDelay) } catch { return }
            }
        }
        .paneSheet(item: $picking, id: "home-place") { picking in
            switch picking {
            case .destination:
                PlaceSearchView(title: "Where to?", allowsCurrentLocation: false, showsTravelTimes: true) { go(to: $0) }
            case .origin(let destination):
                PlaceSearchView(title: "Start from", allowsCurrentLocation: false) { go(to: destination, from: $0) }
            case .home:
                PlaceSearchView(title: "Set Home", allowsCurrentLocation: false) { places.home = $0 }
            case .favorite:
                PlaceSearchView(title: "Add a place", allowsCurrentLocation: false) { places.addFavorite($0) }
            case .work:
                PlaceSearchView(title: "Set Work", allowsCurrentLocation: false) { places.work = $0 }
            }
        }
        .paneSheet(isPresented: $showSettings, id: "settings") { SettingsView() }
        .paneSheet(isPresented: $showSetup, id: "setup") { SetupView() }
        .onChange(of: showSetup) { _, shown in
            guard !shown else { return }
            offersSetup = false
            scene.mayUseLocation = true
            if router.path.isEmpty { scene.showHome() }
            location.requestPermission()
        }
        .paneSheet(isPresented: Bindable(alerts).showAlerts, id: "alerts") { AlertsView() }
        .task { await alerts.refreshStatus() }
        .alert("Can't find where you are", isPresented: .constant(stranded != nil), presenting: stranded) { destination in
            Button("Choose a start") {
                stranded = nil
                picking = .origin(for: destination)
            }
            Button("Cancel", role: .cancel) { stranded = nil }
        } message: { _ in
            Text(location.isDenied ? "Location is off. Pick where you're starting from instead." : "Pick where you're starting from instead.")
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            searchField
            if !router.barIsBeside || router.detent == Router.low {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .systemGray).gradient, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
    }

    /// Whether this launch shows the setup step. Debug: `-setup` always, demos never.
    private func firstRunTurn() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-setup") { return true }
        if Demo.isOn { return false }
        #endif
        return FirstRun.takeTurn()
    }

    private var searchField: some View {
        Button { picking = .destination } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").fontWeight(.semibold)
                Text("Search Beeline").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.fill.tertiary, in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search for a destination")
    }

    private var savedPlaces: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Places").font(.title3.bold())
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    savedSlot("Home", icon: "house.fill", place: places.home, set: .home, tint: Theme.tint) { places.home = nil }
                    savedSlot("Work", icon: "briefcase.fill", place: places.work, set: .work, tint: Color(uiColor: .systemGray)) { places.work = nil }
                    ForEach(places.favorites) { place in
                        shortcut(place.name, icon: "mappin", tint: Theme.tint) { go(to: place) }
                            .contextMenu { Button("Remove place", systemImage: "trash", role: .destructive) { places.removeFavorite(place) } }
                    }
                    shortcut("Add", icon: "plus", tint: Theme.tint, subdued: true) { picking = .favorite }
                        .accessibilityLabel("Add a saved place")
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func savedSlot(_ title: String, icon: String, place: Place?, set: Picking,
                           tint: Color, clear: @escaping () -> Void) -> some View {
        shortcut(title, icon: icon, tint: tint, subtitle: place?.name) {
            if let place { go(to: place) } else { picking = set }
        }
        .accessibilityHint(place.map { "Find a route to " + $0.name } ?? "Choose where to set " + title)
        .contextMenu {
            if place != nil {
                Button("Change \(title)", systemImage: "pencil") { picking = set }
                Button("Remove \(title)", systemImage: "trash", role: .destructive, action: clear)
            }
        }
    }

    private func shortcut(_ title: String, icon: String, tint: Color, subtitle: String? = nil, subdued: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: shortcutSize * 0.43, weight: .semibold))
                    .foregroundStyle(subdued ? tint : .white)
                    .frame(width: shortcutSize, height: shortcutSize)
                    .background((subdued ? tint.opacity(0.20) : tint).gradient, in: .circle)
                VStack(spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(width: shortcutSize + 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var exampleJourney: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try a journey").font(.title3.bold())
            Button {
                router.path.append(.results(.londonExample))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tram.fill").foregroundStyle(Theme.tint)
                        .frame(width: 34, height: 34).background(Theme.tint.opacity(0.15), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("King’s Cross → Canary Wharf").font(.subheadline.weight(.semibold))
                        Text("London example").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 17))
            }
            .buttonStyle(.plain)
        }
    }

    /// The lines you've asked to hear about, with what TfL says about them now.
    @ViewBuilder private var yourLines: some View {
        if !alerts.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Your lines") {
                    Button("Alerts") { alerts.showAlerts = true }
                }
                VStack(spacing: 0) {
                    ForEach(Array(alerts.alerts.enumerated()), id: \.element.id) { index, alert in
                        if index > 0 { Divider().padding(.leading, 12) }
                        Button { alerts.showAlerts = true } label: {
                            HStack {
                                AlertRow(alert: alert, status: alerts.status[alert.id], pending: alerts.delivery.pending[alert.id], compact: true)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .surface(highlighted: alerts.alerts.contains { alerts.status[$0.id]?.issues.contains { $0.level == .closed } == true })
            }
        }
    }

    @ViewBuilder private var recents: some View {
        if !places.recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recents").font(.title3.bold())
                VStack(spacing: 0) {
                    ForEach(Array(places.recents.prefix(5).enumerated()), id: \.element.id) { index, place in
                        if index > 0 { Divider().padding(.leading, 52) }
                        Button { go(to: place) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    if let subtitle = place.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 54)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Set as Home", systemImage: "house") { places.home = place }
                            Button("Set as Work", systemImage: "briefcase") { places.work = place }
                            Button("Remove", systemImage: "trash", role: .destructive) { places.forget(place) }
                        }
                    }
                }
                .background(.fill.tertiary, in: .rect(cornerRadius: 17))
            }
        }
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Leaving near you") {
                if departures.nearby?.value != nil {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshNearby(force: true) } }
                        .labelStyle(.iconOnly)
                }
            }
            NearbyList(state: departures.nearby, locationOff: location.isDenied)
        }
    }

    private var nearbyIsVisible: Bool {
        scenePhase == .active && location.isAuthorized && router.path.isEmpty &&
            picking == nil && !showSetup && !showSettings && !alerts.showAlerts
    }

    private func refreshNearby(force: Bool = false) async {
        guard nearbyIsVisible, let here = try? await location.current(), nearbyIsVisible, !Task.isCancelled else { return }
        scene.receivedHomeFix(here)
        await departures.loadNearby(here, force: force)
    }

    /// Plan from where you are (or a chosen start) to a place, straight away.
    private func go(to destination: Place, from origin: Place? = nil) {
        places.remember(destination)
        Task {
            var start = origin
            if start == nil {
                guard let here = try? await location.current() else {
                    stranded = destination
                    return
                }
                start = .currentLocation(here)
            }
            guard let start else { return }
            router.path.append(.results(JourneyQuery(origin: start, destination: destination, time: .leaveNow)))
        }
    }
}

/// Lines leaving stops within a short walk, soonest first in each direction.
struct NearbyList: View {
    var state: Loadable<[NearbyLine]>?
    var locationOff: Bool
    /// Rows shown before "Show more"; the rest of the one request's lines are behind it.
    var collapsedCount = 3
    @State private var showAll = false

    var body: some View {
        Group {
            if locationOff {
                note("Turn on location to see what's leaving near you.")
            } else {
                switch state {
                case .loaded(let lines) where lines.isEmpty:
                    note("Nothing is leaving from stops within 400 m right now.")
                case .loaded(let lines):
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let all = Array(lines.compactMap { $0.upcoming(at: context.date) }.prefix(10))
                        let shown = showAll ? all : Array(all.prefix(collapsedCount))
                        VStack(spacing: 0) {
                            if all.isEmpty { note("No upcoming departures in the latest board.") }
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                                if index > 0 { Divider().padding(.leading, 12) }
                                NavigationLink(value: Page.line(line)) {
                                    NearbyRow(line: line, now: context.date)
                                }
                                .buttonStyle(.plain)
                            }
                            if all.count > collapsedCount {
                                Divider().padding(.leading, 12)
                                Button(showAll ? "Show fewer" : "Show \(all.count - collapsedCount) more") {
                                    withAnimation(.snappy) { showAll.toggle() }
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.tint)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                    }
                case .failed(let reason):
                    note(reason)
                case .loading, nil:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding departures near you…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
        }
        .surface()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

private struct NearbyRow: View {
    var line: NearbyLine
    var now: Date
    @Environment(Router.self) private var router

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LinePill(mode: line.mode, line: line.line, color: line.lineColor, compact: true)
                .fixedSize(horizontal: router.isNarrow, vertical: false)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.headsign.isEmpty ? line.line : "to \(line.headsign)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(line.stopName) · \(Int((line.distance / 10).rounded()) * 10) m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if line.departures.contains(where: \.isRealtime) { LiveDot() }
                Text(times)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    // On a narrow window the line and the times stay whole and the names give way.
                    .fixedSize(horizontal: router.isNarrow, vertical: false)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(line.mode == .bus ? "Shows where the buses are" : "Shows the next departures")
    }

    /// "Now, 6, 12 min".
    private var times: String {
        let minutes = line.departures.prefix(router.isNarrow ? 2 : .max).map { max(0, Int($0.expected.timeIntervalSince(now) / 60)) }
        guard !minutes.isEmpty else { return "" }
        let parts = minutes.map { $0 == 0 ? "Now" : "\($0)" }
        return parts.joined(separator: ", ") + (minutes.last == 0 ? "" : " min")
    }
}
