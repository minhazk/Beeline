import SwiftUI

/// A line's label in its own colour: mode icon plus its name.
struct LinePill: View {
    var mode: LegMode
    var line: String?
    var color: RGB?
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    init(leg: Leg, compact: Bool = false) {
        (mode, line, color, self.compact) = (leg.mode, leg.line, leg.lineColor, compact)
    }

    init(mode: LegMode, line: String?, color: RGB?, compact: Bool = false) {
        (self.mode, self.line, self.color, self.compact) = (mode, line, color, compact)
    }

    var body: some View {
        let luminance = color?.luminance ?? 0.4
        HStack(spacing: 4) {
            Image(systemName: mode.symbol).imageScale(.small)
            if let line { Text(Self.shortName(line)).lineLimit(1) }
        }
        .font((compact ? Font.caption : .footnote).weight(.semibold))
        .foregroundStyle(luminance < 0.6 ? Color.white : Color.black)
        .padding(.horizontal, compact ? 6 : 8)
        .frame(minHeight: compact ? 20 : 24)
        .background(color.map(Color.init) ?? .gray, in: .rect(cornerRadius: 6))
        .overlay {
            // Pale lines (the Circle, Hammersmith & City) need an edge on white,
            // and the Northern line's black needs one at night.
            if colorScheme == .dark ? luminance < 0.2 : luminance > 0.7 {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
        }
    }

    nonisolated static func shortName(_ line: String) -> String {
        let name = line.replacingOccurrences(of: " line", with: "")
            .replacingOccurrences(of: "Hammersmith & City", with: "H&C")
            .replacingOccurrences(of: "Waterloo & City", with: "W&C")
        // Some operators brand in lower case ("southeastern"); match the rest of the list.
        guard name == name.lowercased(), name.first?.isLetter == true else { return name }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// The journey at a glance: its lines in order, plus any walk long enough to
/// matter (the total walking is spelled out under it).
struct LegStrip: View {
    var legs: [Leg]
    @Environment(Router.self) private var router: Router?

    static let notableWalk: TimeInterval = 5 * 60

    var body: some View {
        let notable = legs.filter { $0.mode.isTransit || $0.duration >= Self.notableWalk }
        let shown = notable.isEmpty ? legs : notable
        if router?.isNarrow == true, shown.contains(where: \.mode.isTransit) {
            // Under 400 pt a walk wrapping onto a line of its own reads as a stray number. Keep
            // one line by dropping the walk at the end, then every walk (the row below says how
            // long the walking is); wrap only if the lines alone don't fit.
            let withoutLastWalk = shown.last?.mode.isTransit == false ? Array(shown.dropLast()) : shown
            ViewThatFits(in: .horizontal) {
                strip(shown, wraps: false)
                strip(withoutLastWalk, wraps: false)
                strip(shown.filter(\.mode.isTransit), wraps: false)
                strip(shown, wraps: true)
            }
        } else {
            strip(shown, wraps: true)
        }
    }

    @ViewBuilder private func strip(_ shown: [Leg], wraps: Bool) -> some View {
        if wraps {
            FlowLayout(spacing: 5) { items(shown) }
        } else {
            HStack(spacing: 5) { items(shown) }.fixedSize()
        }
    }

    @ViewBuilder private func items(_ shown: [Leg]) -> some View {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, leg in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").font(.footnote).foregroundStyle(.tertiary)
                }
                if leg.mode.isTransit {
                    LinePill(leg: leg)
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "figure.walk")
                        Text("\(Int((leg.duration / 60).rounded()))")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Walk \(leg.duration.minutesText)")
                }
            }
    }
}

/// Which source found a journey. Plain on purpose: the lines carry the colour.
struct SourceBadge: View {
    var provider: ProviderID

    var body: some View {
        Text(provider.badge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.ink.opacity(0.06), in: .capsule)
            .accessibilityLabel(provider.name)
    }
}

/// A heading over a group of rows, sentence case, with room for an action.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            trailing.font(.subheadline)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

/// Live dot: the time comes from the operator's live feed, not the timetable.
struct LiveDot: View {
    var body: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.live)
            .accessibilityLabel("Live")
    }
}

/// One tap to ask Citymapper, Google Maps or Apple Maps about the same trip.
struct OpenInRow: View {
    var query: JourneyQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check with another app").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            if let reminder = query.time.handoffTimeReminder {
                Text(reminder).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(OpenIn.allCases) { app in
                    Button { app.open(query) } label: {
                        Text(app.name)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.tint)
                }
            }
        }
    }
}

/// Wraps children onto new lines, for leg strips too long for one row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
