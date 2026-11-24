import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlaceStore.self) private var places
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @State private var picking: SavedSlot?
    /// A key field being typed into.
    @FocusState private var editingKey: String?
    /// The alerts server as typed; closing Settings without "Use this server" drops it.
    @State private var serverDraft = AlertServerDraft()

    enum SavedSlot: String, Identifiable {
        case home = "Home", work = "Work"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            settingsForm.keepsSheetWhenUnfolded(editingKey != nil)
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
                        Label("Alerts for your lines", systemImage: "bell.badge")
                    }
                } footer: {
                    Text("A notification when a line you use regularly is closed or delayed.")
                }

                Section {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        Toggle(isOn: Binding(get: { settings.isEnabled(provider) }, set: { settings.setEnabled(provider, $0) })) {
                            HStack(spacing: 10) {
                                SourceBadge(provider: provider)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(provider.name)
                                    Text(blurb(provider)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Toggle(isOn: $settings.deepSearch) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Deep search")
                            Text("Ask Google and TfL several ways (fewer changes, less walking, rail or bus only) to surface routes their default ranking hides.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Sources") } footer: {
                    // Quiet: what Google's free allowance has left this month, counted on this phone.
                    Text("Google this month: \(GoogleUsage.shared.allowance.usedThisMonth(now: .now)) of \(GoogleAllowance.monthlyCap.formatted()) free requests. Deep search asks Google once past \(GoogleAllowance.deepUntil), and not at all past \(GoogleAllowance.monthlyCap - GoogleAllowance.reserve).")
                }

                ConnectionSections(draft: serverDraft, focus: $editingKey)

                Section("Saved places") {
                    savedRow(.home, place: places.home)
                    savedRow(.work, place: places.work)
                }

                Section("Data") {
                    Text("Route data from Google, Transport for London (Powered by TfL Open Data), and Transitous (transitous.org/sources) with © OpenStreetMap contributors. Apple Maps provides estimates and place search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func blurb(_ provider: ProviderID) -> String {
        switch provider {
        case .google: "Full routes. Needs an API key."
        case .tfl: "London's official planner, incl. National Rail."
        case .transitous: "Open timetables for all of Great Britain."
        case .apple: "Travel-time estimate only (no routes)."
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
