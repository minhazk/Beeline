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
            if !store.alerts.isEmpty {
                Section {
                    ForEach(store.alerts) { alert in
                        NavigationLink {
                            AlertEditor(alert: alert, isNew: false)
                        } label: {
                            AlertRow(alert: alert, status: store.status[alert.id], pending: store.delivery.pending[alert.id])
                        }
                    }
                    .onDelete { offsets in offsets.map { store.alerts[$0].id }.forEach(store.delete) }
                } header: {
                    Text("Your lines")
                } footer: {
                    if let problem = store.statusProblem ?? store.syncProblem {
                        Text(problem).foregroundStyle(Theme.warning)
                    } else if let checked = store.checkedAt {
                        Text("TfL checked at \(checked.clock).")
                    }
                }
            }

            Section {
                Button("Add line alert", systemImage: "plus") { editing = RouteAlert() }
                    .disabled(!store.canAddWatch)
            } footer: {
                if let cleanupProblem = store.cleanupProblem {
                    Text(cleanupProblem).foregroundStyle(Theme.warning)
                }
                if !store.canAddWatch { Text("You can keep up to 30 active watches. Remove one to add another.") }
            }

            if !store.isConfigured {
                Section {
                    NavigationLink("Connect alerts server") {
                        Form { AlertServerSection(draft: serverDraft, focus: $serverField, showsHelp: false) }
                            .navigationTitle("Alerts server")
                            .keepsSheetWhenUnfolded(true)
                    }
                } footer: {
                    Text("Connect a server to receive notifications.")
                }
            } else if !store.alerts.isEmpty {
                notifications
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
            NavigationStack { AlertEditor(alert: alert, isNew: true) }
        }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            switch store.permission?.authorizationStatus {
            case .denied:
                Button("Notifications are off", systemImage: "bell.slash") {
                    openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
                }
                .foregroundStyle(Theme.warning)
            case .authorized, .provisional, .ephemeral:
                LabeledContent {
                    Text(store.permission?.timeSensitiveSetting == .disabled ? "Off" : "On")
                } label: {
                    Label("Time Sensitive", systemImage: "bell.badge")
                }
                if store.permission?.timeSensitiveSetting == .disabled {
                    Button("Turn on Time Sensitive notifications") {
                        openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
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
                Button("Allow notifications", systemImage: "bell") { Task { await store.enablePush() } }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if let testResult { Text(testResult) }
        }
    }
}

/// One alert: its lines, when, and what TfL says now.
struct AlertRow: View {
    var alert: RouteAlert
    var status: AlertStatus.Entry?
    var pending: String? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ForEach(alert.segments) { segment in
                    LinePill(mode: segment.legMode, line: segment.line.name, color: segment.color, compact: true)
                }
            }
            Text(alert.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
            if !compact {
                Text(alert.whenText).font(.caption).foregroundStyle(.secondary)
            }
            if let pending {
                Label("On this phone only. \(pending)", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.warning)
            } else {
                AlertSummary(status: status)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "Good service", the worst of what's wrong, or what's planned on your days.
struct AlertSummary: View {
    var status: AlertStatus.Entry?

    var body: some View {
        if let status {
            if let worst = status.issues.max(by: { $0.level < $1.level }) {
                Label {
                    Text(status.issues.count > 1 ? "\(worst.title), and \(status.issues.count - 1) more" : worst.title)
                } icon: {
                    Image(systemName: worst.level == .minor ? "info.circle" : "exclamationmark.triangle.fill")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(worst.level == .minor ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
            } else {
                Label("Good service", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.live)
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
            }
        } else {
            Text(AlertStore.shared.isConfigured ? "Checking TfL…" : "Not checked: no alert server").font(.caption).foregroundStyle(.tertiary)
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
                    Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
