import SwiftUI

/// Rules that take routes off the list. Remembered, because they're usually
/// about you ("I don't do buses") rather than the trip.
struct FilterSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Changes") {
                    Picker("Changes", selection: $settings.routeFilter.maxChanges) {
                        Text("Any").tag(Int?.none)
                        Text("Up to 1").tag(Int?.some(1))
                        Text("Direct only").tag(Int?.some(0))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Walking") {
                    Picker("Walking", selection: $settings.routeFilter.maxWalkMinutes) {
                        Text("Any").tag(Int?.none)
                        Text("Up to 10 min").tag(Int?.some(10))
                        Text("Up to 5 min").tag(Int?.some(5))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Avoid") {
                    ForEach(ModeGroup.allCases) { group in
                        Toggle(isOn: Binding(
                            get: { settings.routeFilter.avoided.contains(group) },
                            set: { avoid in
                                if avoid { settings.routeFilter.avoided.insert(group) } else { settings.routeFilter.avoided.remove(group) }
                            })) {
                            Label {
                                Text(group.label)
                                if let detail = group.detail { Text(detail) }
                            } icon: {
                                Image(systemName: group.symbol).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
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
}
