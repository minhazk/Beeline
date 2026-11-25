import ActivityKit
import SwiftUI
import WidgetKit

/// The next three trains from a station as dots on a line from now, so the gaps between them show
/// at a glance, with a countdown to the next one. The countdown, and the line filling in to the
/// first train, run on their own; a push from the alerts server brings news (a train gone, a new
/// estimate, a cancellation), and the stale date makes the phone look again as the first leaves.
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
                        Timeline(attributes: attributes, state: state, isStale: context.isStale)
                        if let notice = state.notice { NoticeLine(text: notice) }
                    }
                    .padding(.horizontal, 10)
                }
            } compactLeading: {
                LineDot(attributes: attributes, size: 22).accessibilityLabel("\(attributes.line) from \(attributes.stop)")
            } compactTrailing: {
                if let next {
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

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.warning)
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
