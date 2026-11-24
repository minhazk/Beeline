import MapKit
import SwiftUI

struct PlaceSearchView: View {
    var title: String
    var allowsCurrentLocation: Bool
    /// Choosing where to go: each venue shows how long it takes to get there.
    var showsTravelTimes = false
    var onPick: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @Environment(PlaceStore.self) private var places
    @Environment(LocationService.self) private var location
    @Environment(MapScene.self) private var scene: MapScene?
    @Environment(Router.self) private var router: Router?
    @State private var search = PlaceSearch()
    @State private var resolving = false
    /// Every match for a chain or kind of place, to choose between.
    @State private var venues: VenueList?
    /// Apple Maps' card for a venue: hours, photos, reviews, phone, website.
    @State private var details: MKMapItem?
    @FocusState private var focused: Bool
    /// Whether the field is this view's own (see `SearchField`). Decided as it opens, so a
    /// fold doesn't swap the field under the keyboard.
    @State private var ownsField: Bool?

    struct Venue: Identifiable {
        let id = UUID()
        let item: MKMapItem
        var distance: Double?
        var travelTime: TimeInterval?
    }

    struct VenueList {
        var query: String
        var venues: [Venue]
        var timing = false
    }

    var body: some View {
        NavigationStack {
            List {
                if let venues {
                    venueSection(venues)
                } else if search.text.isEmpty {
                    if allowsCurrentLocation {
                        row(icon: "location.fill", tint: Theme.tint, title: "Current Location", subtitle: nil) {
                            // A fresh fix: the last one the app heard may be where the trip started.
                            Task {
                                resolving = true
                                let here = try? await location.current()
                                resolving = false
                                pick(.currentLocation(here ?? location.last ?? .init(latitude: 0, longitude: 0)))
                            }
                        }
                    }
                    if let home = places.home { row(icon: "house.fill", tint: Theme.tint, title: "Home", subtitle: home.name) { pick(home) } }
                    if let work = places.work { row(icon: "briefcase.fill", tint: Theme.tint, title: "Work", subtitle: work.name) { pick(work) } }
                    ForEach(places.favorites) { place in
                        row(icon: "mappin", tint: Theme.tint, title: place.name, subtitle: place.subtitle) { pick(place) }
                    }
                    if !places.recents.isEmpty {
                        Section("Recent") {
                            ForEach(places.recents) { place in
                                row(icon: "clock", tint: .secondary, title: place.name, subtitle: place.subtitle) { pick(place) }
                            }
                        }
                    }
                } else {
                    ForEach(search.results, id: \.self) { result in
                        let isQuery = result.subtitle.isEmpty || result.subtitle == "Search Nearby"
                        row(icon: isQuery ? "magnifyingglass" : "mappin.circle.fill", tint: .secondary, title: result.title,
                            subtitle: result.subtitle.isEmpty ? nil : result.subtitle) {
                            Task { await open(result) }
                        }
                    }
                }
            }
            .modifier(SearchField(own: ownsField ?? (router?.barIsBeside ?? false), text: $search.text, focused: $focused) {
                Task { await showVenues(matching: search.text) }
            })
            .onChange(of: search.text) { venues = nil }
            // Wide open on a Duo this is a page beside the map, so the places listed are pinned on it.
            .onChange(of: venues?.venues.map(\.id)) {
                guard router?.foldX != nil else { return }
                scene?.showPins(venues?.venues.map { PlaceSearch.place($0.item) } ?? [])
            }
            .onDisappear { scene?.clearPins() }
            .keepsSheetWhenUnfolded(!search.text.isEmpty || venues != nil || details != nil)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss(or: paneClose) } }
            }
            .overlay { if resolving { ProgressView().controlSize(.large) } }
            .mapItemDetailSheet(item: $details, displaysMap: true)
        }
        .onAppear {
            if ownsField == nil { ownsField = router?.barIsBeside ?? false }
            search.bias(to: location.last)
            focused = true
        }
    }

    // MARK: Venues

    private func venueSection(_ list: VenueList) -> some View {
        Section {
            ForEach(list.venues) { venue in
                HStack(spacing: 12) {
                    Button { pick(PlaceSearch.place(venue.item)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.symbol(venue.item.pointOfInterestCategory))
                                .foregroundStyle(Theme.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(venue.item.name ?? "Unnamed place").foregroundStyle(.primary).lineLimit(1)
                                // Distance first: long addresses get cut off.
                                let address = [venue.distance.map(LiveTrip.distanceText),
                                               venue.item.address?.shortAddress ?? venue.item.addressRepresentations?.cityWithContext].compactMap { $0 }
                                if !address.isEmpty {
                                    Text(address.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let time = venue.travelTime {
                                    Text("\(Image(systemName: "tram.fill")) \(time.minutesText) by public transport")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                } else if list.timing {
                                    Text("Working out how long…").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    Button { details = venue.item } label: {
                        Image(systemName: "info.circle").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .tint(Theme.tint)
                    .accessibilityLabel("Opening hours and details for \(venue.item.name ?? "this place")")
                }
            }
        } header: {
            Text("\(list.venues.count) for “\(list.query)”")
        } footer: {
            let times = showsTravelTimes ? "Times are Apple's public transport estimates from where you are. " : ""
            Text("\(times)Tap \(Image(systemName: "info.circle")) for opening hours, photos and reviews.")
        }
    }

    /// A suggestion that stands for several places opens them as a list.
    private func open(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        guard let items = try? await search.items(for: completion), !items.isEmpty else { return }
        if items.count == 1 {
            pick(PlaceSearch.place(items[0], title: completion.title, subtitle: completion.subtitle))
        } else {
            await list(items, for: completion.title)
        }
    }

    private func showVenues(matching text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        resolving = true
        defer { resolving = false }
        guard let items = try? await search.items(matching: text), !items.isEmpty else { return }
        await list(items, for: text)
    }

    private func list(_ items: [MKMapItem], for query: String) async {
        let here = location.last.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let found = items.prefix(12).map { item in Venue(item: item, distance: here.map { item.location.distance(from: $0) }) }
            .sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
        focused = false
        venues = VenueList(query: query, venues: found, timing: showsTravelTimes && location.isAuthorized)
        guard showsTravelTimes, location.isAuthorized else { return }
        // One estimate per venue from Apple (free); the full search across every source runs once you pick.
        let estimates = found.map { venue in Task { try? await AppleEstimator.travelTime(to: venue.item) } }
        for (venue, estimate) in zip(found, estimates) {
            let time = await estimate.value
            guard venues?.query == query, let index = venues?.venues.firstIndex(where: { $0.id == venue.id }) else { return }
            venues?.venues[index].travelTime = time
        }
        withAnimation(.snappy) {
            venues?.timing = false
            venues?.venues.sort { ($0.travelTime ?? .infinity, $0.distance ?? .infinity) < ($1.travelTime ?? .infinity, $1.distance ?? .infinity) }
        }
    }

    static func symbol(_ category: MKPointOfInterestCategory?) -> String {
        switch category {
        case .store: "bag.fill"
        case .restaurant: "fork.knife"
        case .cafe, .bakery: "cup.and.saucer.fill"
        case .nightlife, .brewery, .winery: "wineglass.fill"
        case .pharmacy: "cross.case.fill"
        case .hospital: "cross.fill"
        case .museum: "building.columns.fill"
        case .theater, .movieTheater: "theatermasks.fill"
        case .park, .nationalPark: "tree.fill"
        case .hotel: "bed.double.fill"
        case .fitnessCenter: "figure.run"
        case .library: "books.vertical.fill"
        case .publicTransport: "tram.fill"
        default: "mappin.circle.fill"
        }
    }

    // MARK: Rows

    private func row(icon: String, tint: Color, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }

    private func pick(_ place: Place) {
        onPick(place)
        dismiss(or: paneClose)
    }
}

/// The system's search field. Where the bars are in a column at the side (the Duo's cover)
/// the system's field brings a second close button beside the column's own, so there the
/// field is a plain one: it clears, and the column's button closes.
private struct SearchField: ViewModifier {
    var own: Bool
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    private static let prompt = "Places, addresses or shops"

    func body(content: Content) -> some View {
        if own {
            content.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(Self.prompt, text: $text)
                        .focused(focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit(onSubmit)
                    if !text.isEmpty {
                        Button("Clear text", systemImage: "xmark.circle.fill") { text = "" }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Theme.ink.opacity(0.07), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        } else {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(Self.prompt))
                .searchFocused(focused)
                .onSubmit(of: .search, onSubmit)
        }
    }
}
