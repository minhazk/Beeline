import SwiftUI

/// Re-planning in Go's sheet: a plain line when the trip has changed under you (an earlier
/// Jubilee, a long wait for the 277), or an offer of a faster way with Switch and Keep.
struct ReplanCard: View {
    enum Model {
        case offer(Replan.Message, journey: Journey)
        case status(Replan.Message, symbol: String)
        /// "Find a faster way", running: the star fills in as it does while a search runs.
        case looking(String)
    }

    var model: Model
    /// At Go's low rest: the offer as one row (gain, time, Switch), so it's whole there too.
    var compact = false
    var onSwitch: () -> Void = {}
    var onKeep: () -> Void = {}

    var body: some View {
        switch model {
        case .offer(let message, _) where compact:
            HStack(spacing: 10) {
                FractalStar(size: 20)
                Text(message.compact)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(message.short)
                Spacer(minLength: 0)
                Button("Keep my route", systemImage: "xmark", action: onKeep)
                    .labelStyle(.iconOnly)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
                Button(action: onSwitch) {
                    Text("Switch").font(.subheadline.weight(.semibold)).padding(.horizontal, 6).frame(minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.tint)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(highlighted: true)
        case .offer(let message, let journey):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    // The star marks the best way, as it does on the routes list.
                    FractalStar(size: 20)
                    Text(message.title).font(.headline)
                }
                LegStrip(legs: journey.legs)
                Text(message.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: onSwitch) {
                        Text("Switch").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.tint)
                    .accessibilityHint("Go follows the new way from \(journey.legs.first?.fromName ?? "the next stop")")
                    Button(action: onKeep) {
                        Text("Keep my route").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.ink)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(highlighted: true)
        case .status(let message, let symbol):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title).font(.subheadline.weight(.semibold))
                    Text(message.detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.tint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
        case .looking(let text):
            Label {
                Text(text).font(.subheadline.weight(.semibold))
            } icon: {
                FractalStar(size: 20, lit: [true, false, true, false])
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
        }
    }
}
