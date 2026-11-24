import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlaceStore.self) private var places
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @State private var picking: SavedSlot?
    enum SavedSlot: String, Identifiable {
        case home = "Home", work = "Work"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            settingsForm
        }
    }

    private var settingsForm: some View {
        @Bindable var settings = settings
        return Group {
            Form {
                Section {
                    NavigationLink {
                        AlertsView(isSheet: false)
                    } label: {
                        Label("Line alerts", systemImage: "bell.badge")
                    }
                }

                Section("Route sources") {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        Toggle(provider == .apple ? "Apple Maps estimates" : provider.name,
                               isOn: Binding(get: { settings.isEnabled(provider) }, set: { settings.setEnabled(provider, $0) }))
                    }
                    Toggle("Search more route options", isOn: $settings.deepSearch)
                }

                Section("Saved places") {
                    savedRow(.home, place: places.home)
                    savedRow(.work, place: places.work)
                }

                Section {
                    NavigationLink("Service connections") {
                        ServiceConnectionsView()
                    }
                    NavigationLink("Data credits") {
                        List {
                            Text("Google Routes")
                            Text("Powered by TfL Open Data")
                            Link("Transitous data sources", destination: URL(string: "https://transitous.org/sources")!)
                            Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            Text("Apple Maps estimates and place search")
                        }
                        .navigationTitle("Data credits")
                        .keepsSheetWhenUnfolded(true)
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

    private func savedRow(_ slot: SavedSlot, place: Place?) -> some View {
        Button { picking = slot } label: {
            HStack {
                Label(slot.rawValue, systemImage: slot == .home ? "house.fill" : "briefcase.fill")
                    .foregroundStyle(.primary)
                Spacer()
                Text(place?.name ?? "Set").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .swipeActions {
            if place != nil {
                Button("Clear", role: .destructive) { if slot == .home { places.home = nil } else { places.work = nil } }
            }
        }
    }
}


private struct ServiceConnectionsView: View {
    @FocusState private var editingKey: String?
    @State private var serverDraft = AlertServerDraft()

    var body: some View {
        Form {
            ConnectionSections(draft: serverDraft, focus: $editingKey, showsHelp: false)
            LabeledContent("Google requests this month",
                           value: "\(GoogleUsage.shared.allowance.usedThisMonth(now: .now)) / \(GoogleAllowance.monthlyCap.formatted())")
        }
        .navigationTitle("Service connections")
        .keepsSheetWhenUnfolded(true)
    }
}
