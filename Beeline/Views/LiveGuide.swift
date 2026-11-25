import SwiftUI

extension LiveTrip {
    /// Where a ride leaves from: the platform of the train Go has you catching, once a board
    /// has it, otherwise the plan's.
    func platform(for ride: Leg) -> String? {
        guard let index = journey.legs.firstIndex(where: { $0.id == ride.id }) else { return ride.platform }
        return timeline.steps[index].service?.platform ?? ride.platform
    }
}

/// The instruction across the top of the map during Go: the next turn on a
/// walk, the countdown at a stop, when to get off on a ride.
struct GuidanceBanner: View {
    var trip: LiveTrip
    @Environment(Router.self) private var router

    var body: some View {
        let leg = trip.leg
        HStack(alignment: .top, spacing: 10) {
            icon(leg)
            VStack(alignment: .leading, spacing: 2) {
                primary(leg)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(router.isNarrow ? 3 : 2)
                Text(secondary(leg))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(router.isNarrow ? 3 : 2)
                if let offer = trip.offerMessage {
                    // A faster way takes the last line: the whole line where it fits, the
                    // gain and the time where the banner is narrow (beside the cover's clock).
                    ViewThatFits(in: .horizontal) {
                        Label(offer.short, systemImage: "sparkle").fixedSize()
                        Label(offer.compact, systemImage: "sparkle").fixedSize()
                        Label(offer.compact, systemImage: "sparkle").lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                } else if let then = then(leg) {
                    // Two lines on a narrow window, so the platform at its end isn't cut.
                    Text(then).font(.footnote).foregroundStyle(.secondary).lineLimit(router.isNarrow ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.paper, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        .padding(.horizontal, 10)
        // With no status bar above (the Duo's cover) the banner would touch the top edge.
        .padding(.top, router.hasNoTopInset ? 10 : 2)
        .accessibilityElement(children: .combine)
        .sensoryFeedback(.impact(weight: .medium), trigger: trip.legIndex)
        .sensoryFeedback(.selection, trigger: trip.guidance?.instruction)
        .animation(.snappy, value: trip.legIndex)
    }

    @ViewBuilder private func icon(_ leg: Leg) -> some View {
        Group {
            if leg.mode.isTransit {
                Image(systemName: leg.mode.symbol)
                    .frame(width: 36, height: 36)
                    .foregroundStyle((leg.lineColor?.luminance ?? 0) < 0.6 ? Color.white : Color.black)
                    .background(leg.lineColor.map(Color.init) ?? .gray, in: .circle)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            } else {
                Image(systemName: Maneuver.symbol(trip.guidance?.instruction ?? (trip.isLastLeg ? "arrive" : nil)))
            }
        }
        .font(.title3.weight(.semibold))
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func primary(_ leg: Leg) -> some View {
        if leg.mode.isTransit {
            if trip.missedRide {
                Text("Missed it?")
            } else if trip.isWaiting {
                // In minutes, as the boards say it: "18:20" read as a time of day beside the clock.
                // The last two minutes count down in seconds.
                let left = trip.rideDeparture.timeIntervalSince(trip.now)
                if left >= 120 {
                    Text("\(Int(left / 60)) min")
                } else {
                    Text(timerInterval: trip.now...trip.rideDeparture, countsDown: true)
                }
            } else {
                Text("Get off at \(leg.toName)")
            }
        } else if let instruction = trip.guidance?.instruction {
            Text(instruction)
        } else if let ride = trip.nextRide {
            Text("Walk to \(ride.fromName)")
        } else {
            Text("Walk to \(trip.query.destination.name)")
        }
    }

    private func secondary(_ leg: Leg) -> String {
        let line = LinePill.shortName(leg.line ?? leg.mode.label)
        if leg.mode.isTransit {
            if trip.missedRide { return "Still at \(leg.fromName) · check departures" }
            if trip.isWaiting {
                let service = ["Board \(line)", trip.platform(for: leg).map { leg.standing(at: $0) }].compactMap { $0 }.joined(separator: " · ")
                return service + (leg.headsign.map { $0.lowercased().hasPrefix("via") ? " · \($0)" : " · towards \($0)" } ?? "")
            }
            let arrival = trip.rideArrival
            let minutes = max(0, Int(arrival.timeIntervalSince(trip.now) / 60))
            let when = minutes == 0 ? "Next stop" : "In \(minutes) min, at \(arrival.clock)"
            // The train you're on, once Go knows which, not the one the plan had.
            return trip.yourDeparture.map { "On the \($0.expected.clock): \(when.prefix(1).lowercased() + when.dropFirst())" } ?? when
        }
        if let guidance = trip.guidance {
            let distance = LiveTrip.distanceText(guidance.distance)
            return guidance.instruction != nil ? "In \(distance)" : "\(distance) remaining"
        }
        return leg.duration.minutesText
    }

    /// What comes after this step.
    private func then(_ leg: Leg) -> String? {
        if let ride = trip.nextRide, let departure = trip.nextRideDeparture {
            // The platform with it: it decides where you walk to inside the station.
            return "Then \(LinePill.shortName(ride.line ?? ride.mode.label)) at \(departure.clock)"
                + (trip.platform(for: ride).map { ", \(ride.standing(at: $0))" } ?? "")
        }
        if leg.mode.isTransit, !trip.isWaiting, trip.legIndex + 1 < trip.journey.legs.count {
            let index = trip.legIndex + 1
            let next = trip.journey.legs[index]
            guard next.mode.isTransit else { return "Then walk \(next.duration.minutesText)" }
            let step = trip.timeline.steps[index]
            let when = step.isEstimate ? "" : " at \(step.departure.clock)"
            return "Then \(LinePill.shortName(next.line ?? next.mode.label))\(when)"
                + (trip.platform(for: next).map { ", \(next.standing(at: $0))" } ?? "")
        }
        return nil
    }
}

/// The sheet during Go: when you'll arrive, whether you'll make the next
/// departure, and the step list (tap one to jump to it).
struct LiveGuide: View {
    var trip: LiveTrip
    var onSettings: () -> Void
    var onEnd: () -> Void
    @Environment(Router.self) private var router
    @State private var showsWalk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveGuideHeader(trip: trip, onSettings: onSettings, onEnd: onEnd)

            // A faster way leads, above the step: it's the decision to make now.
            if let offer = trip.offer, let message = trip.offerMessage {
                ReplanCard(model: .offer(message, offer), compact: router.foldX == nil && router.detent == router.goRest,
                           onSwitch: trip.acceptOffer, onKeep: trip.keepRoute)
            }

            // The low sheet keeps the current step within reach.
            if stepLeads { stepButton }

            if trip.offer == nil, let line = replanLine {
                ReplanCard(model: line)
            }

            if let connection = trip.connection, let ride = trip.nextRide {
                ConnectionCard(connection: connection, ride: ride, departure: trip.nextRideDeparture ?? ride.departure,
                               platform: trip.platform(for: ride),
                               board: trip.board, ifMissed: trip.ifMissed,
                               destination: trip.query.destination.name, now: trip.now)
            } else if trip.missedRide, let board = trip.board(for: trip.leg),
                      let next = board.departures.first(where: { $0.expected > trip.now && !$0.isCancelled }) {
                notice("Next \(LinePill.shortName(next.line)) at \(next.expected.clock)" + (next.arrivalThere.map { ", reaching \(trip.leg.toName) at \($0.clock)" } ?? ""),
                       symbol: "arrow.clockwise", tint: Theme.warning)
            } else if trip.position == nil {
                notice("Using the timetable until your location is available.", symbol: "location.slash", tint: .secondary)
            }

            if let watch = trip.busWatch, trip.nextRide != nil || trip.isWaiting {
                LiveBusSummary(watch: watch)
            }

            if !stepLeads { stepButton }

            if trip.canFindFaster {
                Button("Find a faster way", systemImage: "arrow.triangle.branch") { trip.findFaster() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(Theme.tint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }

            if !trip.leg.mode.isTransit, let walk = trip.walk, !walk.steps.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showsWalk) {
                    WalkSteps(state: .loaded(walk))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Walking directions", systemImage: "figure.walk")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                .tint(Theme.tint)
            }
        }
        .onChange(of: trip.leg.id) { showsWalk = false }
        // An offer raises the sheet so the card and its buttons are whole (wide open it already is).
        .onChange(of: trip.offer?.journey.id) { _, offered in
            if offered != nil, router.foldX == nil, router.detent == router.goRest || router.detent == Router.low { router.settle(.medium) }
        }
    }

    /// What re-planning has to say when there's no offer: looking, a hand-asked answer, or
    /// what the timeline did (an earlier ride, a long wait).
    private var replanLine: ReplanCard.Model? {
        switch trip.replan {
        case .looking(let origin): return .looking(Replan.looking(from: origin))
        case .said(let message): return .status(message, symbol: message.title == "No signal" ? "antenna.radiowaves.left.and.right.slash" : "checkmark.circle")
        default: break
        }
        guard let status = trip.replanStatus else { return nil }
        return .status(status, symbol: status.title.contains("wait") ? "hourglass" : status.title.hasPrefix("Running late") ? "tortoise" : "hare")
    }

    /// The step's button is Go's main action, so it comes straight under the header and stays
    /// whole at Go's low rest whatever the warning below it says (a "tight" card runs to three
    /// lines). On a table the sheet rises to the fold, with room for the warning first.
    private var stepLeads: Bool { !router.inTablePose }

    @ViewBuilder private var stepButton: some View {
        if let step = trip.manualStep {
            Button { trip.take(step) } label: {
                Label(title(step), systemImage: symbol(step))
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(Theme.tint)
            .controlSize(router.inTablePose ? .large : .regular)
            .accessibilityHint("Moves Go on to the next step")
            if !stepLeads {
                Text("Or tap a step below to jump to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ step: LiveTrip.Step) -> String {
        switch step {
        case .boarded(let ride): ride.line.map { "I'm on the \(LinePill.shortName($0))" } ?? "I'm on it"
        case .gotOff: "I've got off"
        }
    }

    private func symbol(_ step: LiveTrip.Step) -> String {
        switch step {
        case .boarded(let ride): ride.mode.symbol
        case .gotOff: "figure.walk"
        }
    }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

/// Go's own top row, in place of the page's navigation bar (as Maps has it): when you'll arrive,
/// with Settings and End beside it. It is the sheet's bar at its low rest too.
struct LiveGuideHeader: View {
    var trip: LiveTrip
    var onSettings: () -> Void
    var onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Text("Arrive \(trip.eta.clock)")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .foregroundStyle(Theme.ink)
                Button(action: onEnd) {
                    Text("End")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(Theme.warning)
                .accessibilityHint("Stops following the journey")
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        // Keyed to the clock as shown: a walk moves the estimate by seconds every tick.
        .animation(.snappy, value: trip.eta.clock)
    }

    /// Where to, how long is left, and the walk still ahead when on foot.
    private var detail: String {
        let left = trip.eta.timeIntervalSince(trip.now)
        var parts = [trip.query.destination.name, left > 0 ? "\(left.minutesText) to go" : "Due now"]
        if let walk = trip.remainingWalk, !trip.leg.mode.isTransit { parts.append("\(LiveTrip.distanceText(walk)) walk") }
        return parts.joined(separator: " · ")
    }
}

/// Will you make it? Your walk against the departure, and what to do if not.
private struct ConnectionCard: View {
    var connection: Connection
    var ride: Leg
    /// The departure you're walking to: the one the trip's timeline has you catching.
    var departure: Date
    var platform: String?
    var board: DepartureBoard?
    var ifMissed: IfMissed?
    var destination: String
    var now: Date

    var body: some View {
        let line = LinePill.shortName(ride.line ?? ride.mode.label)
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict).font(.headline)
                Text("\(departure.clock) \(line)" + (platform.map { " · \(ride.standing(at: $0))" } ?? ""))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if let advice { Text(advice).font(.footnote).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .animation(.snappy, value: connection.verdict)
    }

    private var verdict: String {
        let spare = Int((abs(connection.spare) / 60).rounded())
        switch connection.verdict {
        case .comfortable: return "\(spare) min to spare"
        case .tight: return "Tight connection · walk briskly"
        case .missing: return "Likely to miss this connection"
        }
    }

    private var advice: String? {
        guard let board else { return nil }
        switch connection.verdict {
        case .missing, .tight:
            if let ifMissed { return cost(of: ifMissed) }
            guard let next = board.nextAfterPlanned else { return nil }
            let cost = board.arrivalDifference(next).map { " · \($0.signedMinutesText) at \(ride.toName)" } ?? ""
            return "Next \(next.expected.clock)\(cost)"
        case .comfortable:
            guard let earlier = board.earlierThanPlanned(after: now),
                  earlier.expected > connection.ready, let gain = board.arrivalDifference(earlier), gain < -30 else { return nil }
            return "Earlier option \(earlier.expected.clock) · \(Int((-gain / 60).rounded())) min sooner at \(ride.toName)"
        }
    }

    /// What missing it does to the whole trip, not just this ride.
    private func cost(of missed: IfMissed) -> String {
        var parts = ["Next \(missed.next.expected.clock)"]
        if let minutes = missed.cost {
            if missed.costIsFloor {
                parts.append("at least \(max(minutes, 1)) min later at \(destination)")
            } else if minutes == 0 {
                parts.append("same arrival")
            } else {
                parts.append("\(abs(minutes)) min \(minutes > 0 ? "later" : "sooner") at \(destination)")
            }
        }
        if let change = missed.connection {
            let line = LinePill.shortName(change.line ?? change.mode.label)
            parts.append("\(missed.losesConnection ? "misses" : "makes") \(change.departure.clock) \(line)")
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch connection.verdict {
        case .comfortable: "checkmark.circle.fill"
        case .tight: "figure.walk.motion"
        case .missing: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch connection.verdict {
        case .comfortable: Theme.live
        case .tight, .missing: Theme.warning
        }
    }
}
