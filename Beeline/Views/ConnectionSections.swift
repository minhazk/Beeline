import SwiftUI

/// Select a service before showing its credentials.
struct ConnectionSections: View {
    @Environment(AppSettings.self) private var settings
    var focus: FocusState<String?>.Binding

    var body: some View {
        @Bindable var settings = settings
        NavigationLink {
            Form {
                Section("Google Routes API key") {
                    KeyField(title: "API key", text: $settings.googleKeyOverride,
                             hasBuiltIn: settings.hasBuiltInGoogleKey, focus: focus)
                    Link("Get a Routes API key", destination: URL(string: "https://console.cloud.google.com/apis/library/routes.googleapis.com")!)
                }
                Section("Requests this month") {
                    let used = GoogleUsage.shared.allowance.usedThisMonth(now: .now)
                    let cap = GoogleAllowance.monthlyCap
                    LabeledContent("Google Routes", value: "\(used.formatted()) / \(cap.formatted())")
                    ProgressView(value: Double(min(used, cap)), total: Double(cap))
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle("Google Routes")
            .keepsSheetWhenUnfolded(true)
        } label: {
            service("Google Routes", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    configured: !settings.googleKeyOverride.isEmpty || settings.hasBuiltInGoogleKey)
        }
        NavigationLink {
            Form {
                Section("TfL app key") {
                    KeyField(title: "App key", text: $settings.tflKeyOverride, hasBuiltIn: settings.hasBuiltInTfLKey, focus: focus)
                    Link("Get a TfL key", destination: URL(string: "https://api-portal.tfl.gov.uk/")!)
                }
            }
            .navigationTitle("Transport for London")
            .keepsSheetWhenUnfolded(true)
        } label: {
            service("TfL key", symbol: "tram.fill", configured: !settings.tflKeyOverride.isEmpty || settings.hasBuiltInTfLKey)
        }
    }

    private func service(_ title: String, symbol: String, configured: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if configured {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.live)
                    .accessibilityLabel("Configured")
            }
        }
    }
}

/// A key: kept in the Keychain as it is typed, beating any built into the app.
struct KeyField: View {
    var title: String
    @Binding var text: String
    var hasBuiltIn: Bool
    var focus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(title, text: $text)
                .focused(focus, equals: title)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if text.isEmpty {
                Text(hasBuiltIn ? "Built-in key" : "Not set")
                    .font(.caption)
                    .foregroundStyle(hasBuiltIn ? Theme.live : .secondary)
            }
        }
    }
}

/// Keeps edits separate from the active alerts connection until the user applies them.
@MainActor @Observable
final class AlertServerDraft {
    var url = "" {
        didSet {
            if let savedServer, token == savedServer.token, (try? AlertServer.address(url)) != savedServer.url {
                token = ""
            }
        }
    }
    var token = ""
    private var savedServer: AlertServer?
    private var loaded = false
    var working = false
    var note: String?
    var problem: String?

    func load(from store: AlertStore) {
        guard !loaded else { return }
        loaded = true
        reset(to: store)
    }

    func reset(to store: AlertStore) {
        savedServer = store.server.flatMap { $0.isBuiltIn ? nil : $0 }
        url = store.enteredURL
        token = savedServer?.token ?? ""
    }

    /// What's typed differs from what's in use.
    func changed(from store: AlertStore) -> Bool {
        let typed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != store.enteredURL { return true }
        guard !typed.isEmpty else { return false }
        return token.trimmingCharacters(in: .whitespacesAndNewlines) != (store.server?.token ?? "")
    }

    /// Applies the draft (an empty address goes back to the built-in server or none). True
    /// when it was applied; a problem or a note about the old server stays to be shown.
    @discardableResult
    func apply(to store: AlertStore, url: String? = nil, token: String? = nil) async -> Bool {
        working = true
        problem = nil
        note = nil
        defer { working = false }
        do {
            note = try await store.useServer(url: url ?? self.url, token: token ?? self.token)
            reset(to: store)
            return true
        } catch {
            problem = error.message
            return false
        }
    }
}

/// Where alerts are kept and checked: the server built into this app, or your own (worker/),
/// entered here and kept in the Keychain. Nothing changes until "Use this server".
struct AlertServerSection: View {
    @Environment(AlertStore.self) private var store
    @Bindable var draft: AlertServerDraft
    var focus: FocusState<String?>.Binding

    var showsHelp = true

    private static let urlField = "alerts-url", tokenField = "alerts-token"

    var body: some View {
        Group { sections }
        .onChange(of: draft.url) { draft.problem = nil }
        .onChange(of: draft.token) { draft.problem = nil }
        .onAppear { draft.load(from: store) }
    }

    @ViewBuilder private var sections: some View {
        Section {
            TextField("Server address", text: $draft.url, prompt: Text("https://alerts.example.com"))
                .focused(focus, equals: Self.urlField)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focus.wrappedValue = Self.tokenField }
        } header: {
            Text("Server address")
        }
        // The token in a section of its own: a SecureField in the same group as an address is
        // taken for a login, and iOS offers to save the pair as a password.
        Section {
            SecureField("Phone invitation", text: $draft.token)
                .focused(focus, equals: Self.tokenField)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if draft.changed(from: store) {
                Button {
                    focus.wrappedValue = nil
                    Task { await draft.apply(to: store) }
                } label: {
                    HStack {
                        Text(draft.url.trimmingCharacters(in: .whitespaces).isEmpty ? (AlertStore.hasBuiltInServer ? "Use the built-in server" : "Remove this server") : "Use this server")
                        if draft.working { Spacer(); ProgressView() }
                    }
                }
                .disabled(draft.working)
            } else if !store.enteredURL.isEmpty {
                Button(AlertStore.hasBuiltInServer ? "Use the built-in server" : "Remove this server", role: .destructive) {
                    Task { await draft.apply(to: store, url: "", token: "") }
                }
                .disabled(draft.working)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = draft.problem { Text(problem).foregroundStyle(Theme.warning) }
                if let note = draft.note { Text(note).foregroundStyle(Theme.warning) }
                Label(summary, systemImage: store.isConfigured ? "checkmark.circle" : "antenna.radiowaves.left.and.right.slash")
                if showsHelp {
                    Link("Server setup guide", destination: URL(string: "https://github.com/minhazk/Beeline#run-your-own-alerts-server")!)
                }
            }
        }
    }

    private var summary: String {
        switch store.server {
        case let server? where server.isBuiltIn: "Built-in server"
        case let server?: "Connected to \(server.label)"
        case nil: "Server disconnected"
        }
    }
}
