import SwiftUI

/// Shown once, to a new install: Beeline Home works with nothing set, and each optional key says
/// what it adds and where to get it. The same sections as Settings, where all of it can change.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @Environment(AlertStore.self) private var alerts
    @FocusState private var editing: String?
    @State private var serverDraft = AlertServerDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            FractalStar(size: 28)
                            Text("Welcome to Beeline Home").font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                        Text("Nothing here is needed to start. Routes from TfL and Transitous, departure boards and Apple's estimates work as they are.")
                        Text("Each item below is optional and adds something. Fill in any you have, or skip.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)
                }

                ConnectionSections(draft: serverDraft, focus: $editing)

                Section {
                    Button(action: start) {
                        HStack {
                            Text("Start using Beeline Home").fontWeight(.semibold)
                            if serverDraft.working { ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.tint)
                    .disabled(serverDraft.working)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("All of this can be added or changed later in Settings.")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .navigationTitle("Set up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss(or: paneClose) } }
            }
            .keepsSheetWhenUnfolded(editing != nil)
        }
    }

    /// An alerts server typed in full is applied (and the step stays open if that fails);
    /// one half typed is dropped. Keys are saved as they are typed.
    private func start() {
        editing = nil
        guard serverDraft.isCompleteChange(from: alerts) else { return dismiss(or: paneClose) }
        Task {
            if await serverDraft.apply(to: alerts), serverDraft.note == nil { dismiss(or: paneClose) }
        }
    }
}
