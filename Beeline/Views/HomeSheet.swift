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
    @Environment(AppSettings.self) private var settings

    @State private var picking: Picking?
    @State private var showSettings = false
    @ScaledMetric(relativeTo: .body) private var shortcutSize: CGFloat = 60
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
            // Most urgent first: where to, your shortcuts, live status, then history.
            VStack(alignment: .leading, spacing: 18) {
                searchRow
                savedPlaces
                yourLines
                if offersNearby { nearby }
                if places.recents.isEmpty { exampleJourney } else { recents }
                if offersSetup {
                    Button("Set up extras", systemImage: "key.fill") { showSetup = true }
                        .font(.subheadline.weight(.medium))
                        .tint(Theme.tint)
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
        .alert(location.isDenied ? "Location is off" : "Can't find you", isPresented: .constant(stranded != nil), presenting: stranded) { destination in
            Button("Choose a start") {
                stranded = nil
                picking = .origin(for: destination)
            }
            Button("Cancel", role: .cancel) { stranded = nil }
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
                Text("Where to?").foregroundStyle(.secondary)
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

    /// Home, Work, your places: one row of round shortcuts under the field, no heading needed.
    private var savedPlaces: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                savedSlot("Home", icon: "house.fill", place: places.home, set: .home, tint: Theme.tint) { places.home = nil }
                savedSlot("Work", icon: "briefcase.fill", place: places.work, set: .work, tint: Color(uiColor: .systemBrown)) { places.work = nil }
                shortcut("Alerts", icon: "bell.fill", tint: .orange, subdued: alerts.alerts.isEmpty) { alerts.showAlerts = true }
                ForEach(places.favorites) { place in
                    shortcut(place.name, icon: "mappin", tint: Color(uiColor: .systemRed)) { go(to: place) }
                        .contextMenu { Button("Remove place", systemImage: "trash", role: .destructive) { places.removeFavorite(place) } }
                }
                shortcut("Add", icon: "plus", tint: Theme.tint, subdued: true) { picking = .favorite }
                    .accessibilityLabel("Add a saved place")
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// Unset, the circle is pale with "Add" under it: a glance says which ones are ready.
    private func savedSlot(_ title: String, icon: String, place: Place?, set: Picking,
                           tint: Color, clear: @escaping () -> Void) -> some View {
        shortcut(title, icon: icon, tint: tint, subtitle: place == nil ? "Add" : nil, subdued: place == nil) {
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
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: shortcutSize * 0.4, weight: .semibold))
                    .foregroundStyle(subdued ? tint : .white)
                    .frame(width: shortcutSize, height: shortcutSize)
                    .background((subdued ? tint.opacity(0.18) : tint).gradient, in: .circle)
                VStack(spacing: 0) {
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(width: shortcutSize + 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var exampleJourney: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Try it")
            Button {
                router.path.append(.results(.londonExample))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tram.fill").foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Theme.tint.gradient, in: .circle)
                    Text("King’s Cross → Canary Wharf").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 56)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("A London example journey")
            .surface()
        }
    }

    /// The lines you've asked to hear about: pills on the left, TfL's verdict as one coloured word on the right.
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
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        ForEach(alert.segments) { segment in
                                            LinePill(mode: segment.legMode, line: segment.line.name, color: segment.color, compact: true)
                                        }
                                    }
                                    Text(alert.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                LineStatusBadge(status: alerts.status[alert.id], pending: alerts.delivery.pending[alert.id] != nil,
                                                configured: alerts.isConfigured)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 56)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
                .surface(highlighted: alerts.alerts.contains { alerts.status[$0.id]?.issues.contains { $0.level == .closed } == true })
            }
        }
    }

    @ViewBuilder private var recents: some View {
        if !places.recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Recents")
                VStack(spacing: 0) {
                    ForEach(Array(places.recents.prefix(5).enumerated()), id: \.element.id) { index, place in
                        if index > 0 { Divider().padding(.leading, 52) }
                        Button { go(to: place) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
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
                            .frame(minHeight: 52)
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
            SectionHeader("Nearby") {
                if departures.nearby?.value != nil {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshNearby(force: true) } }
                        .labelStyle(.iconOnly)
                }
            }
            NearbyList(state: departures.nearby, locationOff: location.isDenied)
        }
    }

    /// What's leaving nearby is Transitous's to answer, with where you are: with that source
    /// turned off in Settings it isn't asked, here or for a journey's boards (`DepartureStore`).
    private var offersNearby: Bool { settings.isEnabled(.transitous) }

    private var nearbyIsVisible: Bool {
        offersNearby && scenePhase == .active && location.isAuthorized && router.path.isEmpty &&
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
    @Environment(\.openURL) private var openURL
    /// Rows shown before "Show more"; the rest of the one request's lines are behind it.
    var collapsedCount = 3
    @State private var showAll = false

    var body: some View {
        Group {
            if locationOff {
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("Enable location", systemImage: "location.slash")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
            } else {
                switch state {
                case .loaded(let lines) where lines.isEmpty:
                    note("Nothing leaving within 400 m", icon: "moon.zzz.fill")
                case .loaded(let lines):
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let all = Array(lines.compactMap { $0.upcoming(at: context.date) }.prefix(10))
                        let shown = showAll ? all : Array(all.prefix(collapsedCount))
                        VStack(spacing: 0) {
                            if all.isEmpty { note("No departures right now", icon: "moon.zzz.fill") }
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                                if index > 0 { Divider().padding(.leading, 12) }
                                NavigationLink(value: Page.line(line)) {
                                    NearbyRow(line: line, now: context.date)
                                }
                                .buttonStyle(.plain)
                            }
                            if all.count > collapsedCount {
                                Divider().padding(.leading, 12)
                                Button(showAll ? "Fewer" : "\(all.count - collapsedCount) more") {
                                    withAnimation(.snappy) { showAll.toggle() }
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.tint)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                    }
                case .failed(let reason):
                    note(reason, icon: "exclamationmark.triangle.fill")
                case .loading, nil:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .accessibilityLabel("Finding departures near you")
                }
            }
        }
        .surface()
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

/// One line at a glance: its pill, where it's heading, and the next one in big digits.
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
                Text(line.headsign.isEmpty ? line.line : line.headsign)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(Int((line.distance / 10).rounded()) * 10) m · \(line.stopName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            times
                // On a narrow window the line and the times stay whole and the names give way.
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(line.mode == .bus ? "Shows where the buses are" : "Shows the next departures")
    }

    private var minutes: [Int] {
        line.departures.prefix(router.isNarrow ? 2 : 3).map { max(0, Int($0.expected.timeIntervalSince(now) / 60)) }
    }

    /// "6 min" large, "then 12, 19" small under it.
    @ViewBuilder private var times: some View {
        if let first = minutes.first {
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if line.departures.contains(where: \.isRealtime) { LiveDot() }
                    Text(first == 0 ? "Now" : "\(first)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(first == 0 ? Theme.live : Theme.ink)
                    if first > 0 { Text("min").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                if minutes.count > 1 {
                    Text("then " + minutes.dropFirst().map(String.init).joined(separator: ", "))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// TfL's verdict on one of your lines as a single coloured word.
private struct LineStatusBadge: View {
    var status: AlertStatus.Entry?
    var pending: Bool
    var configured: Bool

    var body: some View {
        let look = self.look
        HStack(spacing: 6) {
            if status?.upcoming.isEmpty == false {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Planned works")
            }
            Label(look.word, systemImage: look.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(look.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(look.color.opacity(0.15), in: .capsule)
        }
        .fixedSize()
    }

    private var look: (word: String, icon: String, color: Color) {
        if pending { return ("Not synced", "exclamationmark.circle.fill", Theme.warning) }
        guard let status else {
            return configured ? ("Checking", "ellipsis", .secondary) : ("Off", "bell.slash.fill", .secondary)
        }
        switch status.issues.map(\.level).max() {
        case .closed?: return ("Closed", "xmark.octagon.fill", Color(uiColor: .systemRed))
        case .delays?: return ("Delays", "exclamationmark.triangle.fill", Theme.warning)
        case .minor?: return ("Minor", "info.circle.fill", .secondary)
        case nil: return ("Good", "checkmark.circle.fill", Theme.live)
        }
    }
}
