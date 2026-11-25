import SwiftUI

/// Opened from the optional setup shortcut on a new install.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @Environment(AlertStore.self) private var alerts
    @FocusState private var editing: String?
    @State private var serverDraft = AlertServerDraft()

    var body: some View {
        NavigationStack {
            Form {
                ConnectionSections(draft: serverDraft, focus: $editing)
                if let message = serverDraft.problem ?? serverDraft.note {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
                }
            }
            .navigationTitle("Optional services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", action: finish)
                        .disabled(serverDraft.working)
                }
            }
            .keepsSheetWhenUnfolded(editing != nil)
        }
    }

    private func finish() {
        editing = nil
        guard serverDraft.isCompleteChange(from: alerts) else { return dismiss(or: paneClose) }
        Task {
            if await serverDraft.apply(to: alerts), serverDraft.note == nil { dismiss(or: paneClose) }
        }
    }
}
