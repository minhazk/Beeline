import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlaceStore.self) private var places
    @Environment(AlertStore.self) private var alerts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picking: SavedSlot?

    enum SavedSlot: String, Identifiable {
        case home = "Home", work = "Work"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Saved places") {
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        placeButton(.home, place: places.home)
                        placeButton(.work, place: places.work)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink {
                        AlertsView(isSheet: false)
                    } label: {
                        settingsRow("Line alerts", icon: "bell.fill", color: .orange, value: alerts.alerts.isEmpty ? nil : String(alerts.alerts.count))
                    }
                    NavigationLink {
                        RouteSourcesView()
                    } label: {
                        settingsRow("Route sources", icon: "arrow.triangle.branch", color: .teal,
                                    value: "\(ProviderID.allCases.filter(settings.isEnabled).count) on")
                    }
                }
                Section {
                    NavigationLink {
                        ServiceConnectionsView()
                    } label: {
                        settingsRow("Service connections", icon: "key.fill", color: .indigo)
                    }
                    NavigationLink {
                        List {
                            Text("Google Routes")
                            Text("Powered by TfL Open Data")
                            Link("Transitous data sources", destination: URL(string: "https://transitous.org/sources")!)
                            Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            Text("Apple Maps estimates and place search")
                        }
                        .navigationTitle("Data credits")
                        .keepsSheetWhenUnfolded(true)
                    } label: {
                        settingsRow("Data credits", icon: "info.circle.fill", color: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss(or: paneClose) } }
            }
            .paneSheet(item: $picking, id: "settings-place") { slot in
                PlaceSearchView(title: "Set \(slot.rawValue)", allowsCurrentLocation: false) { place in
                    if slot == .home { places.home = place } else { places.work = place }
                }
            }
        }
    }

    private func settingsRow(_ title: String, icon: String, color: Color, value: String? = nil) -> some View {
        Label {
            HStack {
                Text(title)
                if let value {
                    Spacer()
                    Text(value).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.14))
                        .frame(width: 28, height: 28)
                }
        }
    }

    private func placeButton(_ slot: SavedSlot, place: Place?) -> some View {
        let color: Color = slot == .home ? Theme.tint : Color(uiColor: .systemBrown)
        return Button { picking = slot } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: slot == .home ? "house.fill" : "briefcase.fill").foregroundStyle(color).font(.title2)
                    Spacer()
                    Image(systemName: place == nil ? "plus.circle" : "pencil").foregroundStyle(.secondary)
                }
                Text(slot.rawValue).font(.headline)
                Text(place?.name ?? "Add place").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.group, in: .rect(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit \(slot.rawValue)", systemImage: "pencil") { picking = slot }
            if place != nil {
                Button("Clear \(slot.rawValue)", systemImage: "trash", role: .destructive) { clear(slot) }
            }
        }
    }

    private func clear(_ slot: SavedSlot) {
        if slot == .home { places.home = nil } else { places.work = nil }
    }
}

private struct RouteSourcesView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    Toggle(isOn: Binding(get: { settings.isEnabled(provider) }, set: { settings.setEnabled(provider, $0) })) {
                        HStack(spacing: 12) {
                            Text(provider.badge).font(.caption.bold()).foregroundStyle(Theme.color(provider))
                                .frame(width: 34, height: 34)
                                .background(Theme.color(provider).opacity(0.16), in: .circle)
                            Text(provider == .apple ? "Apple Maps estimates" : provider.name)
                        }
                    }
                }
            }
            Toggle(isOn: $settings.deepSearch) {
                Label("Search more route options", systemImage: "rectangle.stack.badge.plus")
            }
        }
        .navigationTitle("Route sources")
        .keepsSheetWhenUnfolded(true)
    }
}

struct ServiceConnectionsView: View {
    @FocusState private var editingKey: String?

    var body: some View {
        Form { ConnectionSections(focus: $editingKey) }
            .navigationTitle("Service connections")
            .keepsSheetWhenUnfolded(true)
    }
}
