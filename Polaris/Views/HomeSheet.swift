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
    /// The setup step, on a new install's first launch only (`FirstRun`).
    @State private var showSetup = false
    @State private var tookFirstRunTurn = false
    @State private var stranded: Place?
    @State private var didDemo = false

    enum Picking: Identifiable {
        case destination, home, work
        case origin(for: Place)

        var id: String {
            switch self {
            case .destination: "destination"
            case .home: "home"
            case .work: "work"
            case .origin(let place): "origin-\(place.id)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Where the system keeps its bars in a column at the side (the Duo's cover), a
                // hidden bar leaves that column empty and the header costs a row. Settings goes
                // in the column there, and the star beside the search field.
                if router.barIsBeside {
                    HStack(spacing: 10) {
                        FractalStar(size: 26)
                        searchField
                    }
                } else {
                    header
                    searchField
                }
                savedPlaces
                // What you set up and come back to (your lines' problems, recents) comes first;
                // "Leaving near you" is a nice extra, so it sits last and shows only a few rows.
                // (It once led, as the on-the-move answer; that took too much room above them.)
                yourLines
                recents
                nearby
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Theme.paper)
        // Put away, the bar is where to: the search field, whatever the list was scrolled to.
        // Put away, the bar is where to: the star, the search field and Settings on one line,
        // whatever the list was scrolled to. On the cover Settings leaves the system's column for
        // the bar, where the column's own button sat 17 pt above the field's line; it keeps the
        // column's place, in the card's rounded end.
        .lowRestBar {
            HStack(spacing: 10) {
                FractalStar(size: 26)
                searchField
                settingsButton
                    .padding(.leading, router.barIsBeside ? 8 : 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, router.barIsBeside ? LowBar.endInset : 16)
        }
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
            // A new install sees the setup step first, and is asked for location after it: until
            // then nothing on the map or the page asks (MapKit would, for a camera on the user).
            if !tookFirstRunTurn, firstRunTurn() {
                showSetup = true
                scene.mayUseLocation = false
            }
            tookFirstRunTurn = true
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
            case .work:
                PlaceSearchView(title: "Set Work", allowsCurrentLocation: false) { places.work = $0 }
            }
        }
        .paneSheet(isPresented: $showSettings, id: "settings") { SettingsView() }
        .paneSheet(isPresented: $showSetup, id: "setup") { SetupView() }
        .onChange(of: showSetup) { _, shown in
            guard !shown else { return }
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
            Text(location.isDenied ? "Location is off for Beeline Home. Pick where you're starting from instead." : "Pick where you're starting from instead.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FractalStar(size: 26)
            Text("Beeline Home").font(Theme.title(.title2))
            Spacer()
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") { showSettings = true }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(Theme.ink)
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
                Image(systemName: "magnifyingglass").fontWeight(.medium)
                Text("Where to?")
                Spacer()
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .surface()
            .contentShape(.rect(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search for where to go")
    }

    private var savedPlaces: some View {
        HStack(spacing: 10) {
            savedTile("Home", icon: "house.fill", place: places.home, set: .home) { places.home = nil }
            savedTile("Work", icon: "briefcase.fill", place: places.work, set: .work) { places.work = nil }
        }
    }

    private func savedTile(_ title: String, icon: String, place: Place?, set: Picking, clear: @escaping () -> Void) -> some View {
        Button {
            if let place { go(to: place) } else { picking = set }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(Theme.tint)
                    .frame(width: 34, height: 34)
                    .background(Theme.tint.opacity(0.1), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(place?.name ?? "Add").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .surface()
            .contentShape(.rect(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if place != nil {
                Button("Change \(title)", systemImage: "pencil") { picking = set }
                Button("Remove \(title)", systemImage: "trash", role: .destructive, action: clear)
            }
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
                SectionHeader("Recent")
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
                .surface()
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
                note("Turn on location for Beeline Home to see what's leaving near you.")
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
