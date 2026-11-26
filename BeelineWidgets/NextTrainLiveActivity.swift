import ActivityKit
import SwiftUI
import WidgetKit

/// The next three trains from a station as dots on a line from now, so the gaps between them show
/// at a glance, with a countdown to the next one. The countdown, and the line filling in to the
/// first train, run on their own; a push from the alerts server brings news (a train gone, a new
/// estimate, a cancellation), and the stale date makes the phone look again as the first leaves.
/// When the server reports trouble on the way, the card says that instead: how bad, where on your
/// ride and why, with the countdown to the next train kept beside it.
struct NextTrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextTrainAttributes.self) { context in
            NextTrainLockScreen(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(Palette.label)
        } dynamicIsland: { context in
            let attributes = context.attributes, state = context.state
            let next = state.upcoming(at: .now).first { !$0.cancelled }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        LineDot(attributes: attributes, size: 24)
                        Text(attributes.stop).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let next {
                        Minutes(train: next).font(.title3.weight(.bold)).padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let trouble = state.trouble, let notice = state.notice {
                            NoticeLine(text: trouble.cause.map { "\(notice) · \($0)" } ?? notice, color: Palette.trouble(trouble))
                            RideStrip(attributes: attributes, trouble: trouble)
                        } else {
                            Timeline(attributes: attributes, state: state, isStale: context.isStale)
                            if let notice = state.notice { NoticeLine(text: notice) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            } compactLeading: {
                LineDot(attributes: attributes, size: 22).accessibilityLabel("\(attributes.line) from \(attributes.stop)")
            } compactTrailing: {
                if let trouble = state.trouble {
                    // Trouble first: the countdown is a glance at the Lock Screen away.
                    Text(trouble.word(for: state.notice))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.trouble(trouble))
                        .frame(maxWidth: 60)
                        .accessibilityLabel(state.notice ?? "Disruption")
                } else if let next {
                    Minutes(train: next)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: 60)
                } else {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(Palette.secondaryLabel)
                }
            } minimal: {
                LineDot(attributes: attributes, size: 22).accessibilityLabel("\(attributes.line) from \(attributes.stop)")
            }
            .keylineTint(Palette.line(attributes.color) ?? Palette.accent)
        }
    }
}

private struct NextTrainLockScreen: View {
    var attributes: NextTrainAttributes
    var state: NextTrainAttributes.ContentState
    var isStale: Bool

    var body: some View {
        let next = state.upcoming(at: .now).first { !$0.cancelled }
        if let trouble = state.trouble, let notice = state.notice {
            TroubleCard(attributes: attributes, state: state, trouble: trouble, notice: notice, next: next, isStale: isStale)
        } else {
            trains(next: next)
        }
    }

    private func trains(next: NextTrainAttributes.ContentState.Train?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LinePill(attributes: attributes)
                Text(attributes.stop).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Freshness(state: state, isStale: isStale)
                if let next {
                    Minutes(train: next).font(.title2.weight(.bold)).fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(attributes.towards.map { "\(attributes.line) from \(attributes.stop) to \($0)" } ?? "\(attributes.line) from \(attributes.stop)")
            Timeline(attributes: attributes, state: state, isStale: isStale)
            if let notice = state.notice { NoticeLine(text: notice) }
        }
        .foregroundStyle(Palette.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The trains as dots along a line that starts now, spaced by when each leaves; the stretch to
/// the next one fills in the line's colour as it comes.
private struct Timeline: View {
    var attributes: NextTrainAttributes
    var state: NextTrainAttributes.ContentState
    var isStale: Bool

    /// A train's dot and the time under it.
    static let markWidth: CGFloat = 52
    static let dotRow: CGFloat = 19

    var body: some View {
        let now = Date.now
        let trains = state.upcoming(at: now)
        if trains.isEmpty {
            Text(isStale ? "Open Beeline to update" : "No more trains for now")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryLabel)
                .frame(maxWidth: .infinity, minHeight: 40)
        } else {
            let color = Palette.line(attributes.color) ?? Palette.accent
            let next = trains.firstIndex { !$0.cancelled }
            GeometryReader { geometry in
                let xs = Self.positions(trains.map(\.date), now: now, width: geometry.size.width)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Palette.hairline).frame(height: 3).offset(y: Self.dotRow / 2 - 1.5)
                    if let next, trains[next].date > now {
                        // Fills from now to the next train by itself, reaching it as it leaves.
                        ProgressView(timerInterval: now...trains[next].date, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .progressViewStyle(.linear)
                        .tint(color)
                        .frame(width: xs[next])
                        .offset(y: Self.dotRow / 2 - 2)
                    }
                    Circle().fill(Palette.label).frame(width: 11, height: 11).offset(y: Self.dotRow / 2 - 5.5)
                    ForEach(trains.indices, id: \.self) { index in
                        Mark(train: trains[index], isNext: index == next, color: color)
                            .offset(x: xs[index] - Self.markWidth / 2)
                    }
                }
            }
            .frame(height: Self.dotRow + 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(trains.map(Self.spoken).joined(separator: ", "))
        }
    }

    /// Where each dot goes: by how soon it leaves, over at least the next ten minutes, kept far
    /// enough apart that the times under them don't overlap.
    static func positions(_ dates: [Date], now: Date, width: CGFloat) -> [CGFloat] {
        let start = markWidth / 2, end = max(start, width - markWidth / 2)
        let span = max(dates.last.map { $0.timeIntervalSince(now) } ?? 0, 600)
        var xs = dates.map { start + (end - start) * CGFloat(max(0, $0.timeIntervalSince(now)) / span) }
        for i in xs.indices.dropFirst() { xs[i] = max(xs[i], xs[i - 1] + markWidth) }
        for i in xs.indices.reversed() { xs[i] = min(xs[i], i == xs.count - 1 ? end : xs[i + 1] - markWidth) }
        return xs.map { max($0, start) }
    }

    private static func spoken(_ train: NextTrainAttributes.ContentState.Train) -> String {
        let time = train.date.formatted(date: .omitted, time: .shortened)
        if train.cancelled { return "\(time) cancelled" }
        return train.late.map { "\(time), \($0) minutes late" } ?? time
    }

    private struct Mark: View {
        var train: NextTrainAttributes.ContentState.Train
        var isNext: Bool
        var color: Color

        var body: some View {
            VStack(spacing: 3) {
                Group {
                    if train.cancelled {
                        Circle().strokeBorder(Palette.warning, lineWidth: 2).frame(width: 13, height: 13)
                    } else if isNext {
                        Circle().fill(color)
                            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2.5))
                            .overlay(Circle().stroke(color, lineWidth: 1.5))
                            .frame(width: 18, height: 18)
                    } else {
                        Circle().fill(color.opacity(0.7)).frame(width: 13, height: 13)
                    }
                }
                .frame(height: Timeline.dotRow)
                Text(train.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.caption.weight(isNext ? .semibold : .regular))
                    .monospacedDigit()
                    .strikethrough(train.cancelled)
                    .foregroundStyle(train.cancelled || train.late != nil ? Palette.warning : isNext ? Palette.label : Palette.secondaryLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: Timeline.markWidth)
        }
    }
}

/// Trouble on the way, in place of the trains: the line's disc and how bad it is, your ride as a
/// strip with the troubled stretch broken up, and why. The next train's countdown stays.
private struct TroubleCard: View {
    var attributes: NextTrainAttributes
    var state: NextTrainAttributes.ContentState
    var trouble: NextTrainAttributes.ContentState.Trouble
    var notice: String
    var next: NextTrainAttributes.ContentState.Train?
    var isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                LineDot(attributes: attributes, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(notice).font(.headline).foregroundStyle(Palette.trouble(trouble)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(attributes.towards.map { "\(attributes.line) · \(attributes.stop) → \($0)" } ?? "\(attributes.line) · \(attributes.stop)")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let next {
                    VStack(alignment: .trailing, spacing: 0) {
                        Minutes(train: next).font(.title3.weight(.bold))
                        Text("next train").font(.caption2).foregroundStyle(Palette.secondaryLabel)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
            }
            RideStrip(attributes: attributes, trouble: trouble)
            HStack(spacing: 6) {
                Text(trouble.cause ?? stretch ?? "On your ride")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Freshness(state: state, isStale: isStale)
            }
        }
        .foregroundStyle(Palette.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var stretch: String? {
        guard let from = trouble.from, let to = trouble.to else { return nil }
        return "\(from) → \(to)"
    }
}

/// Your ride from where you board to where you get off, in the line's colour: whole where trains
/// run as usual, broken up and lit behind where the trouble is, with a mark where it begins.
private struct RideStrip: View {
    var attributes: NextTrainAttributes
    var trouble: NextTrainAttributes.ContentState.Trouble

    private static let inset: CGFloat = 7
    private static let lineY: CGFloat = 9

    var body: some View {
        let color = Palette.line(attributes.color) ?? Palette.accent
        let tint = Palette.trouble(trouble)
        let stretch = trouble.stretch
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let width = max(geometry.size.width - Self.inset * 2, 1)
                let x = { (share: Double) in Self.inset + width * CGFloat(share) }
                let from = x(stretch.lowerBound), to = max(x(stretch.upperBound), from + 10)
                ZStack(alignment: .topLeading) {
                    line(from: Self.inset, to: Self.inset + width).stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    // The troubled stretch: lit behind, and the line itself broken up.
                    line(from: from, to: min(to, Self.inset + width)).stroke(tint.opacity(0.3), style: StrokeStyle(lineWidth: 15, lineCap: .round))
                    line(from: from, to: min(to, Self.inset + width)).stroke(Palette.background, style: StrokeStyle(lineWidth: 5))
                    line(from: from, to: min(to, Self.inset + width)).stroke(color, style: StrokeStyle(lineWidth: 5, dash: [7, 4]))
                    ForEach([Self.inset, Self.inset + width], id: \.self) { end in
                        Circle().fill(Palette.label)
                            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2))
                            .frame(width: 12, height: 12)
                            .position(x: end, y: Self.lineY)
                    }
                    // Where it begins, when that is part-way along.
                    if stretch.lowerBound > 0.04, stretch.lowerBound < 0.96 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Palette.background, tint)
                            .position(x: from, y: Self.lineY - 0.5)
                    }
                }
            }
            .frame(height: Self.lineY * 2)
            HStack(spacing: 8) {
                Text(attributes.stop).lineLimit(1)
                Spacer(minLength: 4)
                if let towards = attributes.towards { Text(towards).lineLimit(1) }
            }
            .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func line(from: CGFloat, to: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: from, y: Self.lineY))
            path.addLine(to: CGPoint(x: to, y: Self.lineY))
        }
    }

    private var spoken: String {
        if let from = trouble.from, let to = trouble.to { return "Between \(from) and \(to)" }
        return "On your ride from \(attributes.stop)"
    }
}

/// Time to go, counting down by itself ("4:52"), and holding at 0:00; "Due" once it's under half
/// a minute when drawn. SwiftUI's self-updating minutes only come as "13 minutes".
private struct Minutes: View {
    var train: NextTrainAttributes.ContentState.Train

    var body: some View {
        let now = Date.now
        if train.date.timeIntervalSince(now) < 30 {
            Text("Due")
        } else {
            Text(timerInterval: now...train.date, countsDown: true, showsHours: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Live times get a green dot; times the phone hasn't heard about for a while say how old they are.
private struct Freshness: View {
    var state: NextTrainAttributes.ContentState
    var isStale: Bool

    var body: some View {
        let updated = Date(timeIntervalSince1970: state.updated)
        if isStale, updated.timeIntervalSinceNow < -3 * 60 {
            Label {
                Text(updated, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).monospacedDigit()
            } icon: {
                Image(systemName: "clock")
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryLabel)
            .accessibilityLabel("Times from \(updated.formatted(date: .omitted, time: .shortened))")
        } else if state.live {
            Circle().fill(Palette.live).frame(width: 7, height: 7).accessibilityLabel("Live")
        }
    }
}

private struct NoticeLine: View {
    var text: String
    var color = Palette.warning

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line as the app's pills show it: the mode and its short name on the line's colour.
private struct LinePill: View {
    var attributes: NextTrainAttributes

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: attributes.symbol).imageScale(.small)
            Text(attributes.line).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Palette.isPale(attributes.color) ? Color.black : .white)
        .padding(.horizontal, 6)
        .frame(minHeight: 20)
        .background(Palette.line(attributes.color) ?? Palette.accent, in: .rect(cornerRadius: 6))
        .fixedSize()
    }
}

/// The mode in a circle of the line's colour, where there's only room for that.
private struct LineDot: View {
    var attributes: NextTrainAttributes
    var size: CGFloat

    var body: some View {
        Image(systemName: attributes.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Palette.isPale(attributes.color) ? Color.black : .white)
            .frame(width: size, height: size)
            .background(Palette.line(attributes.color) ?? Palette.accent, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
    }
}
