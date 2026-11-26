import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct BeelineWidgets: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
        NextTrainLiveActivity()
    }
}

/// The trip on the Lock Screen and in the Dynamic Island: what to do now, and a
/// countdown that keeps running without the app.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenTrip(state: context.state, destination: context.attributes.destination, isStale: context.isStale)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(Palette.label)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StepIcon(state: state, size: 32).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.countdownLabel).font(.caption2).foregroundStyle(.secondary)
                        Countdown(to: state.countdownTo)
                            .font(.title2.bold())
                            .lineLimit(1)
                    }
                    // A running timer asks for little width, then wraps once it ticks.
                    .frame(minWidth: 64, alignment: .trailing)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(state.detail).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                            Text("Arrive \(state.arrival, format: .dateTime.hour().minute())")
                                .font(.caption).monospacedDigit().fixedSize()
                        }
                        if context.isStale {
                            Text("Open Beeline to update").font(.caption).foregroundStyle(.secondary)
                        } else {
                            MissedConnectionLine(state: state)
                        }
                    }
                    .font(.footnote)
                    // Clear of the island's rounded bottom corners.
                    .padding(.horizontal, 10)
                }
            } compactLeading: {
                StepIcon(state: state, size: 22).accessibilityLabel(state.title)
            } compactTrailing: {
                Countdown(to: state.countdownTo)
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                StepIcon(state: state, size: 22).accessibilityLabel(state.title)
            }
            .keylineTint(Palette.accent)
        }
    }
}

/// Trip colours for the Lock Screen and Dynamic Island, which are rendered outside the app.
enum Palette {
    static let background = dark(.secondarySystemBackground)
    static let label = dark(.label)
    static let secondaryLabel = dark(.secondaryLabel)
    static let tertiaryLabel = dark(.tertiaryLabel)
    static let hairline = dark(.separator)
    static let live = dark(.systemGreen)
    static let accent = dark(.systemBlue)
    static let warning = dark(.systemOrange)

    private static func dark(_ color: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            let darkTraits = traits.modifyingTraits { $0.userInterfaceStyle = .dark }
            return color.resolvedColor(with: darkTraits)
        })
    }

    /// A closure in red, delays in orange.
    static func trouble(_ trouble: NextTrainAttributes.ContentState.Trouble) -> Color {
        trouble.severity == "closed" ? dark(.systemRed) : warning
    }

    static func line(_ hex: String?) -> Color? {
        rgb(hex).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
    }

    /// Pale lines (the Circle) take ink on top, not white.
    static func isPale(_ hex: String?) -> Bool {
        guard let c = rgb(hex) else { return false }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.6
    }

    private static func rgb(_ hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

private struct LockScreenTrip: View {
    var state: TripActivityAttributes.ContentState
    var destination: String
    var isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                StepIcon(state: state, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.headline).lineLimit(2)
                    if !state.detail.isEmpty {
                        Text(state.detail).font(.footnote).foregroundStyle(Palette.secondaryLabel).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(state.countdownLabel).font(.caption.weight(.medium)).foregroundStyle(Palette.secondaryLabel)
                    Countdown(to: state.countdownTo).font(.title2.bold())
                }
                .lineLimit(1)
                .frame(minWidth: 64, idealWidth: 78, maxWidth: 90, alignment: .trailing)
            }
            if !isStale { MissedConnectionLine(state: state) }
            HStack(spacing: 6) {
                Text(isStale ? "Open Beeline to update" : "Step \(state.step) of \(state.stepCount)")
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Text(destination).lineLimit(1)
                Text(state.arrival, format: .dateTime.hour().minute()).monospacedDigit().fixedSize()
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryLabel)
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(Palette.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Keep the cost and the fallback service together on both expanded surfaces.
private struct MissedConnectionLine: View {
    var state: TripActivityAttributes.ContentState

    var body: some View {
        if let detail = state.missDetail {
            if let cost = state.missCostText {
                let consequence = Text("If missed \(cost)").bold()
                    .foregroundStyle(state.missIsCostly ? Palette.warning : Palette.label)
                Text("\(consequence) · \(detail)")
                    .font(.footnote).foregroundStyle(Palette.secondaryLabel).lineLimit(2)
            } else {
                Text(detail).font(.footnote).foregroundStyle(Palette.secondaryLabel).lineLimit(2)
            }
        }
    }
}

/// The mode, in the line's own colour when there is one.
private struct StepIcon: View {
    var state: TripActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        // Walks take the blue that marks you on the map.
        let fill = Palette.line(state.lineColor) ?? Palette.accent
        Image(systemName: state.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Palette.isPale(state.lineColor) ? Color.black : .white)
            .frame(width: size, height: size)
            .background(fill, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
    }
}

/// Counts down to a time, then holds at zero instead of counting up.
private struct Countdown: View {
    var to: Date

    var body: some View {
        let now = Date.now
        if to > now {
            Text(timerInterval: now...to, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text("Now")
        }
    }
}
