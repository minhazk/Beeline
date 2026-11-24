import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct PolarisWidgets: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
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
                    StepIcon(state: state, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.countdownLabel).font(.caption2).foregroundStyle(.secondary)
                        Countdown(to: state.countdownTo)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    // A running timer asks for little width, then wraps once it ticks.
                    .frame(minWidth: 64, alignment: .trailing)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(state.detail).lineLimit(1)
                            Spacer()
                            Text("Arrive \(state.arrival, format: .dateTime.hour().minute())")
                        }
                        .foregroundStyle(.secondary)
                        if let detail = state.missDetail {
                            HStack(spacing: 5) {
                                if let cost = state.missCostText {
                                    Text("If missed \(cost)")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(state.missIsCostly ? Palette.warning : .white)
                                }
                                Text(detail).foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                        }
                    }
                    .font(.footnote)
                    // Clear of the island's rounded bottom corners.
                    .padding(.horizontal, 10)
                }
            } compactLeading: {
                StepIcon(state: state, size: 22)
            } compactTrailing: {
                Countdown(to: state.countdownTo)
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                StepIcon(state: state, size: 22)
            }
            .keylineTint(Palette.accent)
        }
    }
}

/// Trip colours for the Lock Screen and Dynamic Island, which are rendered outside the app.
private enum Palette {
    static let background = dark(.secondarySystemBackground)
    static let label = dark(.label)
    static let secondaryLabel = dark(.secondaryLabel)
    static let accent = dark(.systemBlue)
    static let warning = dark(.systemOrange)

    private static func dark(_ color: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            let darkTraits = traits.modifyingTraits { $0.userInterfaceStyle = .dark }
            return color.resolvedColor(with: darkTraits)
        })
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StepIcon(state: state, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(2)
                    Text(state.detail).font(.subheadline).foregroundStyle(Palette.secondaryLabel).lineLimit(2)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                // How long you have, and what it costs you if that isn't enough:
                // together they say whether to run or there's time for a coffee.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(state.countdownLabel).font(.caption).foregroundStyle(Palette.secondaryLabel)
                    Countdown(to: state.countdownTo).font(.title3.weight(.semibold))
                    if !isStale, let cost = state.missCostText {
                        Text("If missed").font(.caption).foregroundStyle(Palette.secondaryLabel).padding(.top, 3)
                        Text(cost)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.missIsCostly ? Palette.warning : Palette.label)
                    }
                }
                .lineLimit(1)
                .frame(minWidth: 64, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                // Why it costs what it does.
                if !isStale, let detail = state.missDetail {
                    Text(detail).fontWeight(.medium).foregroundStyle(Palette.label).minimumScaleFactor(0.85)
                }
                HStack(spacing: 6) {
                    Text(isStale ? "Open Beeline Home to update" : "Step \(state.step) of \(state.stepCount)")
                    Spacer(minLength: 4)
                    Text("\(destination) at \(state.arrival, format: .dateTime.hour().minute())")
                }
                .foregroundStyle(Palette.secondaryLabel)
            }
            .lineLimit(1)
            .font(.footnote)
        }
        .foregroundStyle(Palette.label)
        .padding(16)
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
        if to > .now {
            Text(timerInterval: Date.now...to, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text("Now")
        }
    }
}
