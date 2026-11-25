import SwiftUI

/// Saved limits on changes, walking and modes.
struct FilterSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Changes") {
                    limits("Changes", selection: $settings.routeFilter.maxChanges) {
                        Text("Any").tag(Int?.none)
                        Text("1 max").accessibilityLabel("At most one change").tag(Int?.some(1))
                        Text("Direct").tag(Int?.some(0))
                    }
                }

                Section("Walking") {
                    limits("Walking", selection: $settings.routeFilter.maxWalkMinutes) {
                        Text("Any").tag(Int?.none)
                        Text("10 min max").accessibilityLabel("At most ten minutes walking").tag(Int?.some(10))
                        Text("5 min max").accessibilityLabel("At most five minutes walking").tag(Int?.some(5))
                    }
                }

                Section("Avoid modes") {
                    ForEach(ModeGroup.allCases) { group in
                        modeToggle(group)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { settings.routeFilter = RouteFilter() }
                        .disabled(settings.routeFilter.activeCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss(or: paneClose) }
                }
            }
        }
    }

    @ViewBuilder private func limits<Options: View>(_ title: String, selection: Binding<Int?>,
                                                     @ViewBuilder options: () -> Options) -> some View {
        let picker = Picker(title, selection: selection, content: options).labelsHidden()
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.inline)
        } else {
            picker.pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
    }

    private func modeToggle(_ group: ModeGroup) -> some View {
        Toggle(isOn: Binding(
            get: { settings.routeFilter.avoided.contains(group) },
            set: { avoid in
                if avoid { settings.routeFilter.avoided.insert(group) } else { settings.routeFilter.avoided.remove(group) }
            }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.label)
                    if let detail = group.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: group.symbol).foregroundStyle(.secondary)
            }
        }
    }
}
