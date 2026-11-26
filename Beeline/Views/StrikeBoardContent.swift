import SwiftUI

struct StrikeBoardContent: View {
    let board: LondonStrikeBoard
    let problem: String?

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Time.london
        return calendar
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = Time.london
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    var body: some View {
        let dated = board.events.filter { !$0.datePending && $0.start != nil }
        let groups = Dictionary(grouping: dated) { event in
            event.start.flatMap { Self.calendar.dateInterval(of: .month, for: $0)?.start }
        }
        let months = groups.keys.compactMap { $0 }.sorted()
        let undated = board.events.filter { !$0.datePending && $0.start == nil }
        let pending = board.events.filter(\.datePending)
        let titles = Set(dated.map(\.title))
        List {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(board.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
            }
            if board.checkingForecast { ProgressView("Checking planned strikes…").font(.footnote) }
            if !undated.isEmpty {
                Section("Happening now") {
                    ForEach(undated) { event in row(event, showTitle: true) }
                }
            }
            ForEach(months, id: \.self) { month in
                Section {
                    ForEach(groups[month] ?? []) { event in row(event, showTitle: titles.count != 1) }
                } header: {
                    VStack(alignment: .leading, spacing: 7) {
                        if month == months.first, titles.count == 1, let title = titles.first {
                            Text(title).font(.headline).foregroundStyle(.primary)
                        }
                        Text(Self.format(month, "MMMM yyyy"))
                    }
                }
            }
            if !pending.isEmpty {
                Section("Dates to confirm") { ForEach(pending) { event in row(event, showTitle: true) } }
            }
            if board.events.isEmpty && !board.checkingForecast {
                Text(board.warnings.isEmpty && problem == nil ? "No strikes listed by TfL" : "No strikes in the available reports")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func range(from start: Date, to end: Date?) -> String {
        let first = Self.format(start, "EEE d")
        guard let end, !Self.calendar.isDate(start, inSameDayAs: end) else { return first }
        let sameYear = Self.calendar.isDate(start, equalTo: end, toGranularity: .year)
        let sameMonth = Self.calendar.isDate(start, equalTo: end, toGranularity: .month)
        let last = Self.format(end, sameMonth ? "EEE d" : sameYear ? "EEE d MMM" : "EEE d MMM yyyy")
        return "\(first) – \(last)"
    }

    private func icon(_ mode: String) -> String {
        switch mode {
        case "bus": "bus.fill"
        case "river-bus": "ferry.fill"
        case "cable-car": "cablecar.fill"
        case "bulletin": "calendar"
        default: "tram.fill"
        }
    }

    private func row(_ event: LondonStrike, showTitle: Bool) -> some View {
        let active = !event.datePending && (event.start ?? .distantPast) <= board.checked
        let tint: Color = active ? .orange : .blue
        return NavigationLink {
            details(event)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(event.mode))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 28, height: 28).background(tint.opacity(0.14), in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let start = event.start {
                        Text(range(from: start, to: event.end))
                        if showTitle { Text(event.title).font(.subheadline).foregroundStyle(.secondary) }
                    } else { Text(event.title) }
                }
                if active && event.start != nil {
                    Spacer()
                    Text("In progress").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
        }
    }

    private func details(_ event: LondonStrike) -> some View {
        List {
            Section {
                Label(event.title, systemImage: icon(event.mode)).font(.headline)
                if let start = event.start { LabeledContent("Starts", value: Self.format(start, "EEE d MMM yyyy, HH:mm")) }
                if let end = event.end { LabeledContent("Ends", value: Self.format(end, "EEE d MMM yyyy, HH:mm")) }
            }
            if !event.details.isEmpty {
                Section("TfL reports") { ForEach(event.details.sorted(), id: \.self) { Text($0) } }
            } else if !event.lines.isEmpty {
                Section("Affected lines") { ForEach(event.lines.sorted(), id: \.self) { Text($0) } }
            }
            Link("TfL strike updates", destination: LondonStrikes.guidance)
        }
        .navigationTitle("Strike details")
        .navigationBarTitleDisplayMode(.inline)
        .keepsSheetWhenUnfolded(true)
    }
}
