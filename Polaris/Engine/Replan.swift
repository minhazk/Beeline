import Foundation

/// Re-planning during Go, as a satnav does when the road changes: when what you've
/// actually done turns the rest of the trip into a long wait or a lost connection,
/// say so, and when another way from your next stop gets there clearly sooner, offer it.
///
/// Everything here is pure: the trip's timeline and log in, a decision out. Asking the
/// planners and showing the offer are Go's job, and only on the events named below,
/// never on a timer.
enum Replan {
    // MARK: Thresholds (named so a change of mind changes a number, not the code)

    /// A wait at a change this long is worth a look...
    static let longWait: TimeInterval = 10 * 60
    /// ...when it's grown by at least this much over the plan's.
    static let waitGrowth: TimeInterval = 7 * 60
    /// Arriving this much later than planned is worth a look.
    static let lateBy: TimeInterval = 8 * 60
    /// An earlier or later ride on the same line that moves the arrival by this much is
    /// worth saying (no search: the timeline already did it).
    static let worthSaying: TimeInterval = 2 * 60
    /// A new way must get there at least this much sooner...
    static let minimumGain: TimeInterval = 5 * 60
    /// ...or this share of the time still to go from where it's asked, if that's more.
    static let gainShare = 0.15
    /// Each change more than the current route costs this much of the gain.
    static let changePenalty: TimeInterval = 3 * 60
    /// Notices at or above this rule a new way out.
    static let ruledOutBy = ServiceNotice.Severity.delays

    /// The trip's re-plans: searches sent, answered or not.
    static let searchesPerTrip = 3
    /// Searches that got no answer (no signal underground), so a dead spot can't loop.
    static let failuresPerTrip = 2
    /// Google at most this often a trip, whatever else.
    static let googlePerTrip = 3
    /// Never two searches closer together than this, whatever the reason.
    static let spacing: TimeInterval = 4 * 60

    // MARK: Why

    /// Why a re-plan is worth asking for. `key` stops the same reason asking twice.
    enum Reason: Hashable, Sendable {
        /// Early: the ride at this change now means a long wait.
        case longWait(leg: Int, wait: TimeInterval)
        /// Late at this change: the ride the plan had is gone, and the next costs a lot.
        case lostConnection(leg: Int, late: TimeInterval)
        /// Still at the stop after the ride you were at left.
        case missed(leg: Int, late: TimeInterval)
        /// The ride the plan had at this change is cancelled on its board.
        case cancelled(leg: Int)
        /// "Find a faster way", tapped.
        case asked

        /// The leg the reason is about; a later reason about the same leg is the same one.
        var key: String {
            switch self {
            case .longWait(let leg, _): "wait.\(leg)"
            case .lostConnection(let leg, _): "late.\(leg)"
            case .missed(let leg, _): "late.\(leg)"
            case .cancelled(let leg): "cancelled.\(leg)"
            case .asked: "asked"
            }
        }
    }

    /// The rides still ahead as the timeline has them, and whether that's a guess. Go looks
    /// for a reason only when this changes (or you board, or finish a leg), not every tick:
    /// a walk's estimate moves by seconds, the ride it picks doesn't.
    static func fingerprint(_ timeline: TripTimeline, from current: Int) -> [String] {
        timeline.steps.indices.dropFirst(current).compactMap { index in
            guard timeline.journey.legs[index].mode.isTransit else { return nil }
            let step = timeline.steps[index]
            return "\(index):\(step.service?.id ?? "-"):\(step.isEstimate)"
        }
    }

    /// The first reason worth a re-plan, if any. `plan` is the journey as found; `board`
    /// gives the boards Go holds, as loaded (their planned departure is the plan's).
    static func reason(plan: Journey, timeline: TripTimeline, log: TripLog, current: Int, missedRide: Bool,
                       board: (Leg) -> DepartureBoard?) -> Reason? {
        let late = timeline.arrival.timeIntervalSince(plan.arrival)
        if missedRide, plan.legs.indices.contains(current), plan.legs[current].mode.isTransit, late >= lateBy {
            return .missed(leg: current, late: late)
        }
        for index in plan.legs.indices.dropFirst(current) where plan.legs[index].mode.isTransit && log.boardings[index] == nil {
            let leg = plan.legs[index]
            let step = timeline.steps[index]
            // Cancelled, and the next one costs enough to matter (not a tube every three minutes).
            if board(leg)?.planned?.isCancelled == true {
                let wait = knownWait(plan: plan, timeline: timeline, at: index, board: board(leg)) ?? 0
                if late >= lateBy || wait >= longWait { return .cancelled(leg: index) }
            }
            guard index > current else { continue }
            if let wait = knownWait(plan: plan, timeline: timeline, at: index, board: board(leg)),
               wait >= longWait, wait - plannedWait(plan, at: index) >= waitGrowth {
                return .longWait(leg: index, wait: wait)
            }
            if late >= lateBy, step.departure > leg.departure.addingTimeInterval(TripTimeline.onPlan) {
                return .lostConnection(leg: index, late: late)
            }
        }
        return nil
    }

    /// How long you'd stand at this ride's stop, as the timeline has it: from the end of the
    /// leg before to the departure it picked. Nil when that isn't known well enough to act on:
    /// a guess past the board, or you'd get there before the board's window starts (it
    /// can't show the earlier ones, so a long wait there says nothing).
    static func knownWait(plan: Journey, timeline: TripTimeline, at index: Int, board: DepartureBoard?) -> TimeInterval? {
        guard index > 0, let board, !board.departures.isEmpty else { return nil }
        let step = timeline.steps[index]
        guard !step.isEstimate, step.service != nil else { return nil }
        let ready = timeline.steps[index - 1].arrival
        let windowStarts = plan.legs[index].departure.addingTimeInterval(-DepartureProvider.boardLead)
        guard ready >= windowStarts else { return nil }
        return max(0, step.departure.timeIntervalSince(ready))
    }

    static func plannedWait(_ plan: Journey, at index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        return max(0, plan.legs[index].departure.timeIntervalSince(plan.legs[index - 1].arrival))
    }

    // MARK: What the timeline already did (said, no search)

    /// What changed about the rest of the trip, in words worth a line in Go: an earlier or
    /// later ride on the same line, or a long wait. Nil while you're on plan.
    enum Status: Equatable, Sendable {
        /// Early or late, now on another departure of the same line at this change.
        case otherRide(leg: Int, service: Departure, by: TimeInterval)
        /// Early, and the ride at this change now means this long a wait.
        case longWait(leg: Int, wait: TimeInterval)
    }

    static func status(plan: Journey, timeline: TripTimeline, log: TripLog, current: Int,
                       board: (Leg) -> DepartureBoard?) -> Status? {
        var other: Status?
        for index in plan.legs.indices.dropFirst(current + 1) where plan.legs[index].mode.isTransit && log.boardings[index] == nil {
            let leg = plan.legs[index]
            if let wait = knownWait(plan: plan, timeline: timeline, at: index, board: board(leg)),
               wait >= longWait, wait - plannedWait(plan, at: index) >= waitGrowth {
                return .longWait(leg: index, wait: wait)
            }
            let step = timeline.steps[index]
            if let service = step.service, service.id != board(leg)?.plannedID {
                let by = timeline.arrival.timeIntervalSince(plan.arrival)
                // The last ride that moved is the one that sets the arrival: the earlier 277, not the Jubilee before it.
                if abs(by) >= worthSaying { other = .otherRide(leg: index, service: service, by: by) }
            }
        }
        return other
    }

    // MARK: Where from

    /// Where a re-plan asks from: the next stop you'll be at, at the timeline's time there,
    /// not your GPS position (underground it's the platform you left).
    struct Origin: Equatable, Sendable {
        /// The first leg a new way would replace; the legs before it stay, with their log.
        var resumeAt: Int
        var name: String
        var coordinate: Coordinate
        var time: Date

        func query(to destination: Place) -> JourneyQuery {
            JourneyQuery(origin: Place(name: name, coordinate: coordinate), destination: destination, time: .departAt(time))
        }
    }

    static func origin(_ timeline: TripTimeline, current: Int, boarded: Bool, now: Date) -> Origin? {
        let legs = timeline.journey.legs
        guard legs.indices.contains(current) else { return nil }
        let leg = legs[current]
        let origin: Origin?
        if leg.mode.isTransit {
            if boarded {
                // On a ride: its stop off, when it gets in.
                origin = leg.end.map { Origin(resumeAt: current + 1, name: leg.toName, coordinate: $0, time: timeline.steps[current].arrival) }
            } else {
                // At its stop: from here, now.
                origin = leg.start.map { Origin(resumeAt: current, name: leg.fromName, coordinate: $0, time: now) }
            }
        } else if let next = legs[safe: current + 1], next.mode.isTransit {
            // Walking to a ride: its stop, when the walk gets you there.
            origin = next.start.map { Origin(resumeAt: current + 1, name: next.fromName, coordinate: $0, time: max(now, timeline.steps[current].arrival)) }
        } else {
            origin = nil
        }
        // Nothing but a walk left from there: nothing to re-plan.
        guard let origin, legs.dropFirst(origin.resumeAt).contains(where: \.mode.isTransit) else { return nil }
        return origin
    }

    // MARK: Is there a better way

    struct Offer: Equatable, Sendable {
        /// The new way from `origin`, as the planner gave it.
        var journey: Journey
        var origin: Origin
        /// How much sooner it gets there than the trip as it's going.
        var gain: TimeInterval
        /// TfL's network status was had and checked against it.
        var statusChecked = true
    }

    /// The best of `candidates` (asked from `origin`, notices already attached) if it beats
    /// the trip as it's going by a clear margin; nil otherwise, and then Go says nothing more.
    static func offer(_ timeline: TripTimeline, from origin: Origin, candidates: [Journey]) -> Offer? {
        let rest = Array(timeline.journey.legs.dropFirst(origin.resumeAt))
        let restChanges = max(0, rest.filter(\.mode.isTransit).count - 1)
        let restSignature = Journey(departure: origin.time, arrival: timeline.arrival, legs: rest, sources: []).routeSignature
        let toGo = timeline.arrival.timeIntervalSince(origin.time)
        let needed = max(minimumGain, gainShare * toGo)

        let scored = candidates.compactMap { candidate -> (Journey, TimeInterval, TimeInterval)? in
            // One you can catch from there, then.
            guard candidate.departure >= origin.time.addingTimeInterval(-60) else { return nil }
            // The same lines arriving sooner is the timeline's job, not an offer.
            guard candidate.routeSignature != restSignature else { return nil }
            guard !candidate.notices.contains(where: { $0.severity >= ruledOutBy }), !candidate.hasDisruption else { return nil }
            let sooner = timeline.arrival.timeIntervalSince(candidate.arrival)
            let score = sooner - changePenalty * Double(max(0, candidate.changes - restChanges))
            return score >= needed ? (candidate, sooner, score) : nil
        }
        guard let best = scored.max(by: { ($0.2, -Double($0.0.changes)) < ($1.2, -Double($1.0.changes)) }) else { return nil }
        return Offer(journey: best.0, origin: origin, gain: best.1)
    }

    /// The trip with the offer taken: the legs before its stop as they went (same ids, so the
    /// log still fits), then the new way. Keeps the journey's id, which the sheet follows.
    static func splice(_ timeline: TripTimeline, plan: Journey, offer: Offer) -> Journey {
        var journey = plan
        journey.legs = Array(timeline.journey.legs.prefix(offer.origin.resumeAt)) + offer.journey.legs
        journey.departure = journey.legs.first?.departure ?? offer.journey.departure
        journey.arrival = offer.journey.arrival
        for tag in offer.journey.sources where !journey.sources.contains(tag) { journey.sources.append(tag) }
        journey.notices = offer.journey.notices
        journey.fare = nil
        journey.hasDisruption = offer.journey.hasDisruption
        return journey
    }

    // MARK: How often

    /// What this trip has asked, so nothing asks twice for the same reason, a declined
    /// offer stays declined, and a dead spot underground can't turn into a loop.
    struct Watch: Codable, Equatable, Sendable {
        private(set) var searches = 0
        private(set) var failures = 0
        private(set) var googleRequests = 0
        private(set) var settled: Set<String> = []
        private(set) var lastAsked: Date?

        /// Whether to ask now for this reason. Go doesn't ask at all with no network path (it
        /// waits for the next event instead), so failures here are answers that never came.
        /// "Find a faster way" skips the same-reason rule and the failure cap (you're asking,
        /// likely back in signal) but not the trip's cap or the spacing.
        func mayAsk(_ reason: Reason, now: Date) -> Bool {
            // Three sends a trip, answered or not; two that got nothing stop the automatic ones.
            guard sends < searchesPerTrip, reason == .asked || failures < failuresPerTrip else { return false }
            if let lastAsked, now.timeIntervalSince(lastAsked) < spacing { return false }
            return reason == .asked || !settled.contains(reason.key)
        }

        /// A search went out. `answered`: at least one source replied. With no answer the
        /// reason stays open, to try once more at the next event (out of the tunnel).
        mutating func asked(_ reason: Reason, now: Date, usedGoogle: Bool, answered: Bool) {
            lastAsked = now
            if usedGoogle { googleRequests += 1 }
            if answered {
                searches += 1
                settled.insert(reason.key)
            } else {
                failures += 1
            }
        }

        var mayUseGoogle: Bool { googleRequests < googlePerTrip }
        var sends: Int { searches + failures }

        /// After a Switch the legs from `index` are new ones: what was settled about the old legs
        /// there no longer means anything (and could match a different leg).
        mutating func forget(from index: Int) {
            settled = settled.filter { key in
                guard let leg = key.split(separator: ".").last.flatMap({ Int($0) }) else { return true }
                return leg < index
            }
        }

        /// "Keep my route": don't ask again for this.
        mutating func declined(_ reason: Reason) { declined(key: reason.key) }
        mutating func declined(key: String) { settled.insert(key) }
    }

    /// Which sources a re-plan asks: TfL and Transitous once each (no deep-search variants),
    /// and Google once only while the month's allowance has room for it.
    static func sources(enabled: Set<ProviderID>, hasGoogleKey: Bool, allowance: GoogleAllowance, watch: Watch = Watch(),
                        now: Date) -> [ProviderID] {
        var sources = [ProviderID.tfl, .transitous].filter(enabled.contains)
        if enabled.contains(.google), hasGoogleKey, watch.mayUseGoogle, allowance.canSpend(1, now: now) { sources.insert(.google, at: 0) }
        return sources
    }
}

/// Google Routes requests this month, against the free allowance. Google counts by its own
/// calendar month (Pacific time); this stops short of the cap so a request Polaris didn't
/// see (another device, a retry) can't tip it into a charge.
struct GoogleAllowance: Equatable, Codable, Sendable {
    /// The lowest free monthly cap among the Routes SKUs Polaris uses.
    static let monthlyCap = 1_000
    /// Kept unused, for counts that drift from Google's.
    static let reserve = 100
    static let googleTime = TimeZone(identifier: "America/Los_Angeles")!

    var month: String
    var used: Int

    init(month: String = "", used: Int = 0) {
        self.month = month
        self.used = used
    }

    static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = googleTime
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    func usedThisMonth(now: Date) -> Int { month == Self.month(of: now) ? used : 0 }

    /// Below this many used, a deep search may ask Google all its ways.
    static let deepUntil = 700

    /// How many Google requests a search may send now: every deep-search variant while under
    /// 700 this month, one while under 900, none past that (re-plans stop at 900 too).
    func searchRequests(deep: Bool, variants: Int, now: Date) -> Int {
        let used = usedThisMonth(now: now)
        guard canSpend(1, now: now) else { return 0 }
        guard deep, used < Self.deepUntil else { return 1 }
        return variants
    }

    func canSpend(_ requests: Int, now: Date) -> Bool {
        usedThisMonth(now: now) + requests <= Self.monthlyCap - Self.reserve
    }

    mutating func spend(_ requests: Int, now: Date) {
        let current = Self.month(of: now)
        if month != current { (month, used) = (current, 0) }
        used += requests
    }
}

// MARK: Words

extension Replan {
    /// What Go says, in each place it says it. One source for the sheet, the banner, the
    /// notification and the Live Activity, so they never disagree.
    struct Message: Equatable, Sendable {
        /// A faster way tapped once it can't be taken any more.
        static let offerGone = Message(title: "That faster way has gone", detail: "Its first ride has left, or you're on another. Carry on as you are.",
                                       short: "That faster way has gone", compact: "Offer gone")

        /// The sheet's card headline, and the notification's title.
        var title: String
        /// The card's second line, and the notification's body.
        var detail: String
        /// The banner's last line and the Live Activity's detail: one line.
        var short: String
        /// The banner's last line where `short` won't fit (the Duo's cover, beside the clock).
        var compact: String
    }

    static func ride(_ leg: Leg) -> String { LinePill.shortName(leg.line ?? leg.mode.label) }

    /// "the DLR to Crossharbour", "the Jubilee, then the 277 to Crossharbour".
    static func summary(_ journey: Journey) -> String {
        let rides = journey.transitLegs
        guard let last = rides.last else { return "walk" }
        return rides.map { "the \(ride($0))" }.joined(separator: ", then ") + " to \(last.toName)"
    }

    /// The timeline's own change, said plainly. No search, no action.
    static func message(_ status: Status, timeline: TripTimeline, checked: Bool) -> Message {
        let legs = timeline.journey.legs
        switch status {
        case .otherRide(let index, let service, let by):
            let leg = legs[index]
            let minutes = Int((abs(by) / 60).rounded())
            let early = by < 0
            return Message(
                title: early ? "You're early: the \(service.expected.clock) \(ride(leg))" : "Running late: the \(service.expected.clock) \(ride(leg))",
                detail: "Arrive \(timeline.arrival.clock), \(minutes) min \(early ? "sooner" : "later").",
                short: "\(early ? "Early" : "Late"): \(service.expected.clock) \(ride(leg)), arrive \(timeline.arrival.clock)",
                compact: "\(early ? "Early" : "Late") · arrive \(timeline.arrival.clock)")
        case .longWait(let index, let wait):
            let leg = legs[index]
            let minutes = Int((wait / 60).rounded())
            let at = timeline.steps[index].departure.clock
            return Message(
                title: "You're early: \(minutes) min wait for the \(ride(leg))",
                detail: "At \(leg.fromName), it leaves \(at)." + (checked ? " Nothing quicker from there." : ""),
                short: "\(minutes) min wait for the \(at) \(ride(leg))",
                compact: "\(minutes) min wait · \(at)")
        }
    }

    /// An offer, with why it came up.
    static func message(_ offer: Offer, reason: Reason, timeline: TripTimeline) -> Message {
        let minutes = Int((offer.gain / 60).rounded())
        let arrive = offer.journey.arrival.clock
        let than: String
        switch reason {
        case .longWait(let index, let wait):
            than = " than waiting \(Int((wait / 60).rounded())) min for the \(ride(timeline.journey.legs[index]))"
        case .lostConnection, .missed:
            than = " than \(timeline.arrival.clock) this way"
        case .cancelled(let index):
            than = ", with the planned \(ride(timeline.journey.legs[index])) cancelled"
        case .asked:
            than = ""
        }
        return Message(
            title: "Faster way from \(offer.origin.name)",
            detail: "Take \(summary(offer.journey)): arrive \(arrive), \(minutes) min sooner\(than)."
                + (offer.statusChecked ? "" : " TfL's line status couldn't be checked."),
            short: "Faster way: \(minutes) min sooner, arrive \(arrive)",
            compact: "\(minutes) min sooner · \(arrive)")
    }

    /// While a search you asked for runs (the star fills in as each source answers).
    static func looking(from origin: Origin) -> String { "Looking for a faster way from \(origin.name)" }

    /// Asked by hand with no signal: nothing is sent; Go asks again at the next stop.
    static func noSignal(at origin: Origin) -> String { "No signal here. Beeline Home will look again at \(origin.name)." }

    /// Asked by hand and nothing beat the trip as it's going.
    static func nothingBetter(_ timeline: TripTimeline, from origin: Origin) -> Message {
        Message(title: "Your route is still the quickest",
                detail: "Nothing gets there sooner from \(origin.name) than \(timeline.arrival.clock).",
                short: "Still the quickest: arrive \(timeline.arrival.clock)",
                compact: "Still the quickest")
    }
}
