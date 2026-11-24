import SwiftUI

/// The board in one line: the ones just before yours, yours, and the next few,
/// with what missing yours (or making an earlier one) does to your arrival.
struct DepartureStrip: View {
    var leg: Leg
    var state: Loadable<DepartureBoard>?
    /// When you can be at this stop at the soonest: after the ride before, for a change.
    var reachable: Date?
    /// Ends with "All departures from …", for a strip that opens the board.
    var linksToBoard = true

    var body: some View {
        switch state {
        case .loaded(let board) where !board.departures.isEmpty:
            TimelineView(.periodic(from: .now, by: 20)) { context in
                content(board, now: context.date)
            }
        case .loaded, .failed:
            Label("No departure times for this stop", systemImage: "clock.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .loading, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking departures…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    private func content(_ board: DepartureBoard, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                ticks(board, now: now, before: 2, after: 3)
                ticks(board, now: now, before: 1, after: 3)
                ticks(board, now: now, before: 1, after: 2)
                ticks(board, now: now, before: 0, after: 1)
            }
            if let line = verdict(board, now: now) {
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.warn ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if linksToBoard {
                HStack(spacing: 3) {
                    Text("All departures from \(board.stopName)")
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tint)
            }
        }
    }

    private func ticks(_ board: DepartureBoard, now: Date, before: Int, after: Int) -> some View {
        let anchor = board.planned.flatMap { p in board.departures.firstIndex { $0.id == p.id } }
            ?? board.departures.firstIndex { $0.expected >= leg.departure.addingTimeInterval(-60) }
            ?? 0
        let shown = board.departures[max(0, anchor - before)..<min(board.departures.count, anchor + after + 1)]
        return HStack(spacing: 4) {
            ForEach(shown) { departure in
                Tick(departure: departure, caption: caption(departure, board: board, now: now),
                     isPlanned: departure.id == board.plannedID, isGone: departure.expected < max(now, reachable ?? now))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func caption(_ departure: Departure, board: DepartureBoard, now: Date) -> String {
        if departure.isCancelled { return "cancelled" }
        if departure.id == board.plannedID { return departure.expected < now ? "gone" : "yours" }
        if departure.expected < now { return "gone" }
        let difference = board.arrivalDifference(departure)
            ?? departure.expected.timeIntervalSince(leg.departure)
        return abs(difference) < 30 ? "same" : difference.signedMinutesText
    }

    /// The cost of missing it, or the reward for running.
    private func verdict(_ board: DepartureBoard, now: Date) -> (text: String, warn: Bool)? {
        guard let planned = board.planned else { return nil }
        let there = leg.toName.isEmpty ? "there" : leg.toName
        if planned.isCancelled {
            if let next = board.nextAfterPlanned {
                return ("Your \(planned.scheduled.clock) is cancelled. The next is \(next.expected.clock).", true)
            }
            return ("Your \(planned.scheduled.clock) is cancelled.", true)
        }
        var parts: [String] = []
        if planned.isLate { parts.append("Running \(Int(planned.delay / 60)) min late.") }
        if let earlier = board.earlierThanPlanned(after: max(now, reachable ?? now)), let gain = board.arrivalDifference(earlier), gain < -30 {
            parts.append("Make the \(earlier.expected.clock) and you reach \(there) \(Int((-gain / 60).rounded())) min sooner.")
        }
        if let next = board.nextAfterPlanned, let cost = board.arrivalDifference(next) {
            parts.append("Miss it and the \(next.expected.clock) gets you there \(Int((cost / 60).rounded())) min later.")
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " "), planned.isLate)
    }
}

private struct Tick: View {
    var departure: Departure
    var caption: String
    var isPlanned: Bool
    var isGone: Bool
    @ScaledMetric(relativeTo: .footnote) private var width = 44
    @ScaledMetric(relativeTo: .footnote) private var height = 40

    var body: some View {
        VStack(spacing: 1) {
            Text(departure.expected.clock)
                .font(.footnote.weight(isPlanned ? .bold : .medium))
                .monospacedDigit()
                .strikethrough(departure.isCancelled)
                .foregroundStyle(departure.isLate || departure.isCancelled ? Theme.warning : Theme.ink)
            Text(caption)
                .font(.caption2.weight(isPlanned ? .semibold : .regular))
                .foregroundStyle(isPlanned ? Theme.tint : .secondary)
        }
        .frame(width: width, height: height)
        .background(isPlanned ? Theme.tint.opacity(0.12) : Color(uiColor: .quaternarySystemFill), in: .rect(cornerRadius: 9))
        .overlay {
            if isPlanned { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.tint, lineWidth: 1) }
        }
        .opacity(isGone && !isPlanned ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// The full board for one boarding stop: everything that also stops where the
/// journey gets off, earlier and later, with yours marked.
struct BoardSheet: View {
    let leg: Leg

    @Environment(DepartureStore.self) private var departures
    @Environment(MapScene.self) private var scene

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    switch departures.board(leg) {
                    case .loaded(let board):
                        ForEach(board.alerts) { AlertLine(alert: $0).padding(.horizontal, 4) }
                        if board.departures.isEmpty {
                            note("Nothing in the timetable stops at \(leg.toName) from here around \(leg.departure.clock).")
                        } else {
                            TimelineView(.periodic(from: .now, by: 20)) { context in
                                rows(board, now: context.date)
                            }
                            .onAppear {
                                if let id = board.plannedID { reader.scrollTo(id, anchor: .center) }
                            }
                        }
                        Text("Times from Transitous (open timetables), live where marked. Each row shows when it reaches \(leg.toName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    case .failed(let reason):
                        note(reason)
                    case .loading, nil:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Departures")
        .lowRestBar()
        .navigationBarTitleDisplayMode(.inline)
        .task { await departures.load(leg) }
        .refreshable { await departures.load(leg, force: true) }
        .onAppear { scene.showBoarding(leg) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(departures.board(leg)?.value?.stopName ?? leg.fromName)
                .font(Theme.title(.title2))
            HStack(spacing: 6) {
                LinePill(leg: leg, compact: true)
                Text("and anything else stopping at \(leg.toName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func rows(_ board: DepartureBoard, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(board.departures.enumerated()), id: \.element.id) { index, departure in
                if index > 0 { Divider().padding(.leading, 74) }
                BoardRow(departure: departure, isPlanned: departure.id == board.plannedID, now: now,
                         difference: departure.id == board.plannedID ? nil : board.arrivalDifference(departure),
                         destination: leg.toName)
                    .id(departure.id)
            }
        }
        .surface()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .surface()
    }
}

/// The board as a panel on the map half, wide open on a Duo.
struct BoardPanel: View {
    let leg: Leg
    @Environment(\.paneClose) private var paneClose

    var body: some View {
        NavigationStack {
            BoardSheet(leg: leg)
                .environment(\.boardIsNarrow, true)
                // In a panel this small rows showed through a soft-edged title bar: make it solid.
                .toolbarBackground(Theme.paper, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { paneClose?.run() }
                    }
                }
        }
    }
}

extension EnvironmentValues {
    /// Set where a board sits in less width than its window gives (a panel on the map half).
    @Entry var boardIsNarrow = false
}

private struct BoardRow: View {
    var departure: Departure
    var isPlanned: Bool
    var now: Date
    var difference: TimeInterval?
    var destination: String
    @Environment(Router.self) private var router
    @Environment(\.boardIsNarrow) private var boardIsNarrow

    /// Under 400 pt for its row: the window is narrow, or the board is in a panel.
    private var isNarrow: Bool { router.isNarrow || boardIsNarrow }

    private var isGone: Bool { departure.expected < now }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(departure.expected.clock)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(departure.isCancelled)
                    .foregroundStyle(departure.isLate || departure.isCancelled ? Theme.warning : Theme.ink)
                if departure.isLate {
                    Text(departure.scheduled.clock).font(.caption).monospacedDigit().strikethrough().foregroundStyle(.secondary)
                }
            }
            .frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if isNarrow {
                    // Narrow, the line's name and the headsign stay whole: side by side when they
                    // fit, the headsign under the line when they don't.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            pill.fixedSize()
                            headsign.lineLimit(1).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            pill.fixedSize()
                            headsign.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        pill
                        headsign.lineLimit(1)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    if departure.isRealtime { LiveDot() }
                    Text(status)
                        .font(.subheadline.weight(isPlanned ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(departure.isCancelled ? Theme.warning : Theme.ink)
                }
                if isPlanned {
                    Text("Yours").font(.caption.weight(.semibold)).foregroundStyle(Theme.tint)
                } else if let difference, !departure.isCancelled {
                    Text(difference.signedMinutesText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 60)
        .background {
            if isPlanned {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.tint.opacity(0.08))
                    .strokeBorder(Theme.tint.opacity(0.7), lineWidth: 1)
                    .padding(3)
            }
        }
        .opacity(isGone && !isPlanned ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }

    private var pill: LinePill {
        LinePill(mode: departure.mode, line: departure.line, color: departure.lineColor, compact: true)
    }

    private var headsign: some View {
        Text(departure.headsign.isEmpty ? departure.line : departure.headsign)
            .font(.subheadline.weight(.medium))
    }

    private var detail: String {
        var parts: [String] = []
        // The page's heading names the stop already; a narrow window has no room to repeat it.
        if let there = departure.arrivalThere { parts.append(isNarrow ? "Arrives \(there.clock)" : "\(destination) \(there.clock)") }
        if let platform = departure.platform { parts.append("platform \(platform)") }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        if departure.isCancelled { return "Cancelled" }
        let minutes = Int(departure.expected.timeIntervalSince(now) / 60)
        if isGone { return "Gone" }
        if minutes < 1 { return "Now" }
        return minutes < 60 ? "\(minutes) min" : departure.expected.clock
    }
}
