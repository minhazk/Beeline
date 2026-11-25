import SwiftUI
@preconcurrency import UserNotifications

/// The lines you use regularly. Beeline's server watches them while you travel and
/// sends a Time Sensitive notification when one closes or is delayed.
struct AlertsView: View {
    @Environment(AlertStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @Environment(\.openURL) private var openURL
    @State private var editing: RouteAlert?
    @State private var testResult: String?
    @State private var testing = false
    @State private var serverDraft = AlertServerDraft()
    @FocusState private var serverField: String?
    /// Inside Settings it's pushed; from the home page it's its own sheet.
    var isSheet = true

    var body: some View {
        if isSheet {
            NavigationStack { content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss(or: paneClose) } } } }
        } else {
            content
        }
    }

    private var content: some View {
        // Inside Settings it is a page pushed in that sheet.
        contentForm.keepsSheetWhenUnfolded(!isSheet)
    }

    private var contentForm: some View {
        Form {
            if store.alerts.isEmpty {
                // A removal that didn't reach the server is said here too, with Try again.
                if let problem = store.syncProblem { trouble(problem) }
                emptyState
                if store.isConfigured { server } else { connect }
            } else {
                // Whatever stops alerts arriving comes first, with the button that fixes it.
                if !store.isConfigured { connect }
                if let problem = store.statusProblem ?? store.syncProblem { trouble(problem) }
                if store.isConfigured, needsPermissionAction { notifications }
                lines
                if store.isConfigured, !needsPermissionAction { notifications }
                if store.isConfigured { server }
            }
        }
        .navigationTitle("Line alerts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshStatus(force: true) }
        .task {
            await store.refreshPermission()
            await store.refreshStatus()
        }
        .paneSheet(item: $editing, id: "new-alert") { alert in
            NewLineAlert(alert: alert)
        }
    }

    // MARK: Nothing watched yet

    private var emptyState: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 38, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.tint)
                    .frame(width: 84, height: 84)
                    .background(Theme.tint.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text("No lines saved").font(.title3.bold())
                Button {
                    editing = RouteAlert()
                } label: {
                    Label("Add a line", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .listRowBackground(Color.clear)
        } footer: {
            if let cleanupProblem = store.cleanupProblem {
                Text(cleanupProblem).foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: Your lines

    private var lines: some View {
        Section {
            ForEach(store.alerts) { alert in
                NavigationLink {
                    AlertEditor(alert: alert, isNew: false)
                } label: {
                    AlertRow(alert: alert, verdict: store.verdict(for: alert.id), pending: store.delivery.pending[alert.id])
                }
            }
            .onDelete { offsets in offsets.map { store.alerts[$0].id }.forEach(store.delete) }
            Button("Add a line", systemImage: "plus") { editing = RouteAlert() }
                .disabled(!store.canAddWatch)
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Your lines")
                Spacer(minLength: 8)
                if let headline { Text(headline.text).foregroundStyle(headline.troubled ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary)) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if store.statusProblem == nil, let checked = store.checkedAt { Text("Updated \(checked.clock)") }
                if let cleanupProblem = store.cleanupProblem { Text(cleanupProblem).foregroundStyle(Theme.warning) }
                if !store.canAddWatch { Text("30-line limit reached") }
            }
        }
    }

    /// "2 disrupted", or "All good" once every line has been checked.
    private var headline: (text: String, troubled: Bool)? {
        let troubled = store.alerts.filter { store.status[$0.id]?.issues.contains { $0.level != .minor } == true }.count
        if troubled > 0 { return ("\(troubled) disrupted", true) }
        guard store.isConfigured, store.statusProblem == nil, store.syncProblem == nil,
              store.delivery.pending.isEmpty, store.alerts.allSatisfy({ store.status[$0.id]?.issues.isEmpty == true }) else { return nil }
        return ("All good", false)
    }

    // MARK: What needs doing

    private var serverForm: some View {
        Form { AlertServerSection(draft: serverDraft, focus: $serverField, showsHelp: true) }
            .navigationTitle("Alerts server")
            .navigationBarTitleDisplayMode(.inline)
            .keepsSheetWhenUnfolded(true)
    }

    /// Within reach once connected too: a server entered wrongly, one no longer trusted, or an
    /// invitation that was replaced can always be changed or removed.
    private var server: some View {
        Section {
            NavigationLink {
                serverForm
            } label: {
                LabeledContent {
                    Text(store.server.map { $0.isBuiltIn ? "Built in" : $0.label } ?? "")
                } label: {
                    Label("Alerts server", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
    }

    private var connect: some View {
        Section {
            NavigationLink {
                serverForm
            } label: {
                AlertActionRow(symbol: "antenna.radiowaves.left.and.right.slash",
                               title: "Connect alerts server",
                               detail: "Push notifications are off",
                               tint: store.alerts.isEmpty ? Theme.tint : Theme.warning)
            }
        }
    }

    private func trouble(_ problem: String) -> some View {
        Section {
            AlertActionRow(symbol: "exclamationmark.triangle.fill", title: troubleTitle, detail: problem, tint: Theme.warning)
            Button("Try again", systemImage: "arrow.clockwise") {
                Task {
                    if store.syncProblem != nil { store.resume() }
                    await store.refreshStatus(force: true)
                }
            }
        }
    }

    private var troubleTitle: String {
        guard store.statusProblem != nil else { return "Alerts may be out of date" }
        return store.status.isEmpty ? "Couldn't check your lines" : "Couldn't check some lines"
    }

    /// Notifications that won't arrive, or would arrive late: asked about above the lines.
    private var needsPermissionAction: Bool {
        guard let permission = store.permission else { return false }
        switch permission.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return permission.timeSensitiveSetting == .disabled
        default: return true
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
    }

    @ViewBuilder private var notifications: some View {
        if let permission = store.permission {
            Section {
                switch permission.authorizationStatus {
                case .denied:
                    Button(action: openNotificationSettings) {
                        AlertActionRow(symbol: "bell.slash.fill", title: "Turn on notifications",
                                       detail: "Open notification settings", tint: Theme.warning)
                    }
                case .authorized, .provisional, .ephemeral:
                    if permission.timeSensitiveSetting == .disabled {
                        Button(action: openNotificationSettings) {
                            AlertActionRow(symbol: "bell.badge.fill", title: "Turn on Time Sensitive",
                                           detail: "Allow alerts during Focus", tint: Theme.warning)
                        }
                    } else {
                        LabeledContent {
                            Text("On")
                        } label: {
                            Label("Time Sensitive", systemImage: "bell.badge")
                        }
                    }
                    Button {
                        testing = true
                        Task {
                            testResult = await store.sendTest()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Label("Send a test notification", systemImage: "paperplane")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                default:
                    Button {
                        Task { await store.enablePush() }
                    } label: {
                        AlertActionRow(symbol: "bell.fill", title: "Allow notifications",
                                       detail: "Get disruption alerts", tint: Theme.tint)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                if let testResult { Text(testResult) }
            }
        }
    }
}

/// Begin with the line itself. The schedule opens as soon as a stretch is chosen.
private struct NewLineAlert: View {
    @State var alert: RouteAlert

    var body: some View {
        if alert.segments.isEmpty {
            LinePicker(dismissesAfterPick: false) { alert.segments = [$0] }
        } else {
            NavigationStack { AlertEditor(alert: alert, isNew: true) }
                .keepsSheetWhenUnfolded(true)
        }
    }
}

/// Something to fix, as one row: what's wrong in bold, why it matters under it.
struct AlertActionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One alert: its lines, when, and what TfL says now.
struct AlertRow: View {
    var alert: RouteAlert
    var verdict: AlertStore.Verdict
    var pending: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph.font(.title3).frame(width: 26).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.displayName).font(.body.weight(.semibold)).lineLimit(2)
                state
                pills
                Text(alert.whenText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var pills: some View {
        FlowLayout(spacing: 5) {
            ForEach(alert.segments) { segment in
                LinePill(mode: segment.legMode, line: segment.line.name, color: segment.color, compact: true)
            }
        }
    }

    @ViewBuilder private var state: some View {
        if let pending {
            Text("On this phone only. \(pending)")
                .font(.caption).foregroundStyle(Theme.warning)
        } else {
            AlertSummary(verdict: verdict)
        }
    }

    @ViewBuilder private var glyph: some View {
        if pending != nil {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
        } else if let status = verdict.entry {
            switch status.issues.map(\.level).max() {
            case .closed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.warning)
            case .delays: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            case .minor: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            case nil: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.live)
            }
        } else if AlertStore.shared.isConfigured, verdict == .unavailable {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
        } else {
            Image(systemName: AlertStore.shared.isConfigured ? "circle.dotted" : "bell.slash").foregroundStyle(.tertiary)
        }
    }
}

/// "Good service", the worst of what's wrong, or what's planned on your days.
struct AlertSummary: View {
    var verdict: AlertStore.Verdict

    var body: some View {
        if let status = verdict.entry {
            if let worst = status.issues.max(by: { $0.level < $1.level }) {
                Text(status.issues.count > 1 ? "\(worst.title) +\(status.issues.count - 1)" : worst.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(worst.level == .minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
            } else {
                Text("Good service").font(.subheadline.weight(.medium)).foregroundStyle(Theme.live)
            }
            if let next = status.upcoming.first {
                Label {
                    Text("Planned\(next.from.map { " \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" } ?? ""): \(next.title)")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if status.upcomingUnknown {
                Label("Planned works couldn't be checked", systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if !AlertStore.shared.isConfigured {
            Text("Server disconnected").font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text(verdict == .unavailable ? "Couldn't check TfL" : "Checking TfL…")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// A whole TfL notice: what, how bad, and its own words.
struct AlertIssueRow: View {
    var issue: AlertStatus.Issue
    var planned = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: planned ? "calendar" : issue.level == .minor ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(planned || issue.level == .minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.subheadline.weight(.semibold))
                if planned, let from = issue.from {
                    Text(from.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !issue.detail.isEmpty {
                    DisclosureGroup("Details") {
                        Text(issue.detail).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
