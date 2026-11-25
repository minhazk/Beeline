import SwiftUI

/// Opened from the optional setup shortcut on a new install.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @FocusState private var editing: String?

    var body: some View {
        NavigationStack {
            Form {
                ConnectionSections(focus: $editing)
            }
            .navigationTitle("Optional services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss(or: paneClose) }
                }
            }
            .keepsSheetWhenUnfolded(editing != nil)
        }
    }
}
