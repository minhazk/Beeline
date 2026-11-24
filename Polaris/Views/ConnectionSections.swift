import SwiftUI

/// The optional things a person can set: the same items, in the same words, in the first-run
/// setup step and in Settings. Each value lives in one place (the Keychain, through AppSettings
/// and AlertStore), so the two screens are two views of it.
enum SetupItem {
    case google, tfl, alerts, contact

    var title: String {
        switch self {
        case .google: "Google Routes API key"
        case .tfl: "TfL app key"
        case .alerts: "Alerts server"
        case .contact: "Contact for Transitous"
        }
    }

    /// What it gives you.
    var purpose: String {
        switch self {
        case .google: "Adds Google's routes and fares to every search."
        case .tfl: "TfL answers without one; a key lifts its limit of 50 requests a minute."
        case .alerts: "Needed for alerts on your lines: a small server of your own watches TfL while Beeline Home is closed and sends the notifications."
        case .contact: "Transitous is run by volunteers and asks apps to say who to reach about their requests. Blank uses this build's contact, if it has one."
        }
    }

    /// Where to get it.
    var source: String {
        switch self {
        case .google: "From console.cloud.google.com: enable the Routes API, then create a key limited to iOS apps and the Routes API, with a daily cap."
        case .tfl: "Free from api-portal.tfl.gov.uk."
        case .alerts: "Run beeline-alerts on Cloudflare's free plan; the README shows how. Enter its address and APP_TOKEN."
        case .contact: "Your email address or a web page of yours."
        }
    }

    /// What it is for, that it's optional, and where to get it, as a section footer.
    var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(purpose)
            Text("Optional. \(source)").foregroundStyle(.secondary)
        }
    }
}

/// Google, TfL, the alerts server and the Transitous contact, as Form sections.
struct ConnectionSections: View {
    @Environment(AppSettings.self) private var settings
    var draft: AlertServerDraft
    var focus: FocusState<String?>.Binding

    var body: some View {
        @Bindable var settings = settings
        Section {
            KeyField(title: SetupItem.google.title, text: $settings.googleKeyOverride, hasBuiltIn: settings.hasBuiltInGoogleKey, focus: focus)
        } footer: { SetupItem.google.caption }

        Section {
            KeyField(title: SetupItem.tfl.title, text: $settings.tflKeyOverride, hasBuiltIn: settings.hasBuiltInTfLKey, focus: focus)
        } footer: { SetupItem.tfl.caption }

        AlertServerSection(draft: draft, focus: focus)

        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField(SetupItem.contact.title, text: $settings.contactOverride, prompt: Text("you@example.com or a web address"))
                    .focused(focus, equals: "contact")
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                let typed = settings.contactOverride.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty, Contact.valid(typed) == nil {
                    Text("Not an email or web address, so the build's default is used.").font(.caption).foregroundStyle(Theme.warning)
                }
            }
        } header: {
            Text(SetupItem.contact.title)
        } footer: { SetupItem.contact.caption }
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
                Text(hasBuiltIn ? "Using the key built into this app" : "Not set")
                    .font(.caption)
                    .foregroundStyle(hasBuiltIn ? Theme.live : .secondary)
            }
        }
    }
}

/// The alerts server's fields as typed: a draft until "Use this server" (or the setup step's
/// final button) applies it. Leaving the screen without applying keeps the server in use as it was.
@MainActor @Observable
final class AlertServerDraft {
    var url = ""
    var token = ""
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
        url = store.enteredURL
        token = store.server.map { $0.isBuiltIn ? "" : $0.token } ?? ""
    }

    /// What's typed differs from what's in use.
    func changed(from store: AlertStore) -> Bool {
        let typed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != store.enteredURL { return true }
        guard !typed.isEmpty else { return false }
        return token.trimmingCharacters(in: .whitespacesAndNewlines) != (store.server?.token ?? "")
    }

    /// An address that passes and a token, differing from what's in use.
    func isCompleteChange(from store: AlertStore) -> Bool {
        let typed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return changed(from: store) && !typed.isEmpty && (try? AlertServer.address(typed)) != nil
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            Text(SetupItem.alerts.title)
        } footer: {
            SetupItem.alerts.caption
        }
        // The token in a section of its own: a SecureField in the same group as an address is
        // taken for a login, and iOS offers to save the pair as a password.
        Section {
            SecureField("Token", text: $draft.token)
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
                Text(summary)
            }
        }
    }

    private var summary: String {
        switch store.server {
        case let server? where server.isBuiltIn: "Using the server built into this app. Enter another to use your own instead."
        case let server?: "Using \(server.label). Its token and this phone's secret for it are kept in the Keychain."
        case nil: "Alerts are off until a server is set."
        }
    }
}
