import SwiftUI

/// A faster route leads with the time it saves. The full comparison is available
/// before switching, including what prompted the search.
struct ReplanCard: View {
    enum Model {
        case offer(Replan.Message, Replan.Offer)
        case status(Replan.Message, symbol: String)
        case looking(String)
    }

    var model: Model
    var compact = false
    var onSwitch: () -> Void = {}
    var onKeep: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch model {
        case .offer(let message, let offer):
            if compact && !typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        gain(message)
                        Spacer(minLength: 0)
                        switchButton(offer)
                        Button(action: onKeep) {
                            Text("Keep").font(.subheadline.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Keep my route")
                    }
                    if !offer.statusChecked { statusWarning }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    gain(message)
                    Text(message.title).font(.subheadline)
                    LegStrip(legs: offer.journey.legs)
                    if !offer.statusChecked { statusWarning }
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        switchButton(offer)
                        Button(action: onKeep) {
                            Text("Keep my route").font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                    }
                    DisclosureGroup {
                        Text(message.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Why this route?").font(.footnote.weight(.medium)).frame(minHeight: 44)
                    }
                    .id(offer.journey.id)
                }
                .tint(Theme.tint)
            }
        case .status(let message, let symbol):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title).font(.subheadline.weight(.semibold))
                    Text(message.detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.tint)
            }
            .accessibilityElement(children: .combine)
        case .looking(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func gain(_ message: Replan.Message) -> some View {
        Label {
            Text(message.compact).font(.headline).monospacedDigit()
        } icon: {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.tint)
        }
        .accessibilityLabel(message.short)
    }

    private var statusWarning: some View {
        Label("Line status unconfirmed", systemImage: "exclamationmark.triangle")
            .font(.footnote).foregroundStyle(Theme.warning)
    }

    private func switchButton(_ offer: Replan.Offer) -> some View {
        Button(action: onSwitch) {
            Text("Switch").font(.subheadline.weight(.semibold)).padding(.horizontal, 6).frame(minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.tint)
        .accessibilityHint("Go follows the new route from \(offer.origin.name)")
    }
}
