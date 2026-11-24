import SwiftUI

/// One alert: which lines, between where, on which days and at what times.
struct AlertEditor: View {
    @State var alert: RouteAlert
    var isNew: Bool

    @Environment(AlertStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @State private var addingLine = false
    @State private var customDays = false
    /// The alert as it opened, to tell whether it has been edited.
    @State private var original: RouteAlert?

    enum Days: String, CaseIterable, Identifiable {
        case weekdays = "Weekdays", everyDay = "Every day", weekends = "Weekends", custom = "Custom"
        var id: Self { self }
        var days: [Int]? {
            switch self {
            case .weekdays: Array(1...5)
            case .everyDay: Array(1...7)
            case .weekends: [6, 7]
            case .custom: nil
            }
        }
    }

    var body: some View {
        let saveProblem = store.saveProblem(for: alert)
        Form {
            if !isNew, let status = store.status[alert.id] { now(status) }

            Section {
                ForEach(alert.segments) { segment in
                    HStack(spacing: 10) {
                        LinePill(mode: segment.legMode, line: segment.line.name, color: segment.color, compact: true)
                        Text(segment.stretch).lineLimit(2)
                    }
                }
                .onDelete { alert.segments.remove(atOffsets: $0) }
                Button("Add a line", systemImage: "plus") { addingLine = true }
                    .disabled(alert.segments.count >= RouteAlert.maxSegments)
            } header: {
                Text("Lines")
            } footer: {
                Text("Choose two stations to set a direction, or watch the whole line.")
            }

            Section {
                if alert.ends != nil {
                    Picker("Default direction", selection: $alert.way) {
                        ForEach([RouteAlert.Direction.both, .out, .back], id: \.self) { Text(alert.label($0)).tag($0) }
                    }
                }
                Picker("Days", selection: daysChoice) {
                    ForEach(Days.allCases) { Text($0.rawValue).tag($0) }
                }
                if daysChoice.wrappedValue == .custom {
                    ForEach([1, 2, 3, 4, 5, 6, 7], id: \.self) { day in
                        Button {
                            if alert.days.contains(day) { alert.days.removeAll { $0 == day } } else { alert.days.append(day) }
                            alert.days.sort()
                        } label: {
                            HStack {
                                Text(Calendar.current.weekdaySymbols[day % 7]).foregroundStyle(.primary)
                                Spacer()
                                if alert.days.contains(day) { Image(systemName: "checkmark").foregroundStyle(Theme.tint) }
                            }
                        }
                    }
                }
                // By position, so editing a time doesn't remake its row mid-edit.
                ForEach(alert.windows.indices, id: \.self) { index in
                    let from = DatePicker("From", selection: minutes(slot(index, \.start)), displayedComponents: .hourAndMinute).labelsHidden()
                    let to = DatePicker("To", selection: minutes(slot(index, \.end)), displayedComponents: .hourAndMinute).labelsHidden()
                    let times = HStack {
                        from
                        Text("to").foregroundStyle(.secondary)
                        to
                    }
                    .fixedSize()
                    if alert.ends != nil {
                        // The way beside the times when it fits, under them when it doesn't, and
                        // everything stacked at the largest text sizes.
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                times
                                Spacer(minLength: 8)
                                wayMenu(index)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                times
                                wayMenu(index)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                from
                                Text("to").foregroundStyle(.secondary)
                                to
                                wayMenu(index, wraps: true)
                            }
                        }
                    } else {
                        HStack {
                            times
                            Spacer(minLength: 0)
                        }
                    }
                }
                .onDelete { alert.windows.remove(atOffsets: $0) }
                Button("Add a time", systemImage: "plus") {
                    let last = alert.windows.last?.end ?? 8 * 60
                    alert.windows.append(RouteAlert.TimeWindow(start: min(last + 60, 22 * 60), end: min(last + 180, 23 * 60 + 45)))
                }
                .disabled(alert.windows.count >= RouteAlert.maxWindows)
            } header: {
                Text("When you travel")
            } footer: {
                if alert.ends != nil {
                    Text("Choose a direction for each travel time.")
                }
            }

            Section {
                Toggle("Minor delays too", isOn: $alert.minorDelays)
            } footer: {
                Text("Live alerts during travel times. Planned works at 7 pm the evening before.")
            }

            Section {
                TextField(alert.defaultName, text: $alert.name)
            } header: {
                Text("Name")
            } footer: {
                if let saveProblem, !isNew || !alert.segments.isEmpty || !alert.name.isEmpty {
                    Text(saveProblem).foregroundStyle(Theme.warning)
                }
            }

            if !isNew {
                Section {
                    Button("Delete alert", role: .destructive) {
                        store.delete(alert.id)
                        dismiss(or: isNew ? paneClose : nil)
                    }
                }
            }
        }
        .onAppear { if original == nil { original = alert } }
        // A page pushed inside a sheet, or an edit not yet saved.
        .keepsSheetWhenUnfolded(!isNew || (original.map { $0 != alert } ?? false))
        .navigationTitle(isNew ? "New alert" : alert.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss(or: isNew ? paneClose : nil) } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") {
                    if store.save(alert) { dismiss(or: isNew ? paneClose : nil) }
                }
                .disabled(saveProblem != nil)
            }
        }
        .paneSheet(isPresented: $addingLine, id: "line-picker") {
            LinePicker { segment in
                if alert.segments.count < RouteAlert.maxSegments, !alert.segments.contains(segment) { alert.segments.append(segment) }
            }
        }
    }

    /// A time's way: the alert's (shown quieter) until you pick one, which then stays as picked.
    private func wayMenu(_ index: Int, wraps: Bool = false) -> some View {
        let own = alert.windows.indices.contains(index) && alert.windows[index].direction != nil
        let current = alert.windows.indices.contains(index) ? alert.way(of: alert.windows[index]) : alert.way
        return Menu {
            Picker("Direction", selection: Binding {
                current
            } set: { choice in
                // Kept as chosen, even when it matches Which way now.
                guard alert.windows.indices.contains(index) else { return }
                alert.windows[index].direction = choice
            }) {
                ForEach([RouteAlert.Direction.both, .out, .back], id: \.self) { Text(alert.label($0)).tag($0) }
            }
            if own {
                Section {
                    Button("Use default direction") {
                        guard alert.windows.indices.contains(index) else { return }
                        alert.windows[index].direction = nil
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(alert.label(current)).lineLimit(wraps ? nil : 1).multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .fixedSize(horizontal: !wraps, vertical: true)
            .foregroundStyle(own ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel("Direction for this time")
        .accessibilityValue(alert.label(current))
    }

    @ViewBuilder private func now(_ status: AlertStatus.Entry) -> some View {
        Section("Now") {
            if status.issues.isEmpty {
                Label("Good service", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.live)
            }
            ForEach(status.issues) { AlertIssueRow(issue: $0) }
        }
        if !status.upcoming.isEmpty {
            Section("Planned, when you travel") {
                ForEach(status.upcoming) { AlertIssueRow(issue: $0, planned: true) }
            }
        }
    }

    private var daysChoice: Binding<Days> {
        Binding {
            if customDays { return .custom }
            return Days.allCases.first { $0.days.map(Set.init) == Set(alert.days) } ?? .custom
        } set: { choice in
            customDays = choice == .custom
            if let days = choice.days { alert.days = days }
        }
    }

    /// A time's start or end, safe while a deleted row is still on screen.
    private func slot(_ index: Int, _ field: WritableKeyPath<RouteAlert.TimeWindow, Int>) -> Binding<Int> {
        Binding {
            alert.windows.indices.contains(index) ? alert.windows[index][keyPath: field] : 0
        } set: { value in
            guard alert.windows.indices.contains(index) else { return }
            alert.windows[index][keyPath: field] = value
        }
    }

    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }
}

/// Choose a line, then where you get on and off.
struct LinePicker: View {
    var onPick: (RouteAlert.Segment) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.paneClose) private var paneClose
    @State private var lines: [TfLLines.Line]?
    @State private var problem: String?
    @State private var search = ""

    private static let groups: [(String, String)] = [
        ("tube", "Underground"), ("elizabeth-line", "Elizabeth line"), ("overground", "Overground"),
        ("dlr", "DLR"), ("tram", "Tram"), ("national-rail", "National Rail"),
    ]

    var body: some View {
        NavigationStack {
            List {
                if let lines {
                    ForEach(Self.groups, id: \.0) { mode, title in
                        let shown = lines.filter { $0.mode == mode && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        if !shown.isEmpty {
                            Section(title) {
                                ForEach(shown) { line in
                                    NavigationLink {
                                        StationPicker(line: line, from: nil) { segment in
                                            onPick(segment)
                                            dismiss(or: paneClose)
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            LinePill(mode: line.legMode, line: nil, color: LineColors.color(line: line.name, mode: line.legMode), compact: true)
                                                .frame(width: 32)
                                            Text(line.name)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if let problem {
                    LoadProblem(text: problem) { await load() }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .searchable(text: $search, prompt: "Line")
            .keepsSheetWhenUnfolded(!search.isEmpty)
            .navigationTitle("Choose a line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss(or: paneClose) } } }
            .task { await load() }
        }
    }

    private func load() async {
        problem = nil
        do { lines = try await TfLLines.lines() } catch { problem = "Couldn't get TfL's lines." }
    }
}

/// Where you get on (or the whole line), then where you get off.
struct StationPicker: View {
    var line: TfLLines.Line
    /// Nil while choosing where you get on.
    var from: TfLLines.Station?
    var onPick: (RouteAlert.Segment) -> Void

    @State private var route: TfLLines.Route?
    @State private var problem: String?
    @State private var search = ""

    var body: some View {
        List {
            if let route {
                if from == nil, search.isEmpty {
                    Section {
                        Button {
                            onPick(route.segment(line, from: nil, to: nil))
                        } label: {
                            Label("The whole line", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    } footer: {
                        Text("Or choose where you get on.")
                    }
                }
                Section {
                    ForEach(route.stations.filter { $0 != from && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { station in
                        if let from {
                            Button(station.name) { onPick(route.segment(line, from: from, to: station)) }
                                .foregroundStyle(.primary)
                        } else {
                            NavigationLink(station.name) { StationPicker(line: line, from: station, onPick: onPick) }
                        }
                    }
                }
            } else if let problem {
                LoadProblem(text: problem) { await load() }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $search, prompt: "Station")
        // Pushed inside the line picker.
        .keepsSheetWhenUnfolded(true)
        .navigationTitle(from.map { "From \($0.name) to" } ?? "Get on at")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        problem = nil
        do { route = try await TfLLines.route(line.id) } catch { problem = "Couldn't get the \(line.name)'s stations." }
    }
}

private struct LoadProblem: View {
    var text: String
    var retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).foregroundStyle(.secondary)
            Button("Try again") { Task { await retry() } }
        }
    }
}
