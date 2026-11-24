import Foundation

/// How the list is ordered. Each order weighs time against changes and walking
/// rather than sorting on one key, so a couple of minutes less walking never
/// lifts a route above one that's an hour quicker.
enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case best, fastest, fewestChanges, leastWalking

    var id: Self { self }

    var label: String {
        switch self {
        case .best: "Best"
        case .fastest: "Fastest"
        case .fewestChanges: "Fewest changes"
        case .leastWalking: "Least walking"
        }
    }

    /// Minutes of travel a change is worth, and what each minute on foot costs
    /// on top of the time it takes.
    var weights: (change: Double, walkMinute: Double) {
        switch self {
        case .best: (5, 1)
        case .fastest: (1, 0.25)
        case .fewestChanges: (25, 0.5)
        case .leastWalking: (4, 3)
        }
    }
}

/// Modes grouped the way people think about avoiding them.
enum ModeGroup: String, CaseIterable, Identifiable, Codable, Sendable {
    case tube, rail, light, bus, water

    var id: Self { self }

    var label: String {
        switch self {
        case .tube: "Underground"
        case .rail: "Trains"
        case .light: "DLR and trams"
        case .bus: "Buses and coaches"
        case .water: "Boats and cable car"
        }
    }

    var detail: String? { self == .rail ? "National Rail, Overground, Elizabeth line" : nil }

    var symbol: String {
        switch self {
        case .tube: "tram.fill.tunnel"
        case .rail: "train.side.front.car"
        case .light: "tram.fill"
        case .bus: "bus.fill"
        case .water: "ferry.fill"
        }
    }

    init?(_ mode: LegMode) {
        switch mode {
        case .tube: self = .tube
        case .rail, .overground, .elizabeth: self = .rail
        case .dlr, .tram: self = .light
        case .bus, .coach: self = .bus
        case .ferry, .cableCar: self = .water
        case .walk, .cycle, .other: return nil
        }
    }
}

struct RouteFilter: Codable, Equatable, Sendable {
    var maxChanges: Int?
    var maxWalkMinutes: Int?
    var avoided: Set<ModeGroup> = []

    var activeCount: Int { [maxChanges != nil, maxWalkMinutes != nil, !avoided.isEmpty].filter { $0 }.count }

    func allows(_ journey: Journey) -> Bool {
        if let maxChanges, journey.changes > maxChanges { return false }
        // Half a minute's grace: sources round walks differently.
        if let maxWalkMinutes, journey.walkingTime > Double(maxWalkMinutes * 60 + 30) { return false }
        return !journey.transitLegs.contains { ModeGroup($0.mode).map(avoided.contains) ?? false }
    }
}

/// One card on the list: the best-placed departure of a sequence of lines,
/// with the other departures on the same lines folded into it.
struct RouteOption: Identifiable, Hashable, Sendable {
    var journey: Journey
    /// When else you could leave and take the same lines.
    var otherDepartures: [Date] = []
    /// Every source that found these lines, at any departure.
    var providers: [ProviderID] = []

    var id: UUID { journey.id }
}

enum JourneyRanker {
    struct Ranked: Equatable {
        /// Worth a look, in order.
        var top: [RouteOption] = []
        /// Beaten outright by another route, far behind the best, or through a reported closure.
        var more: [RouteOption] = []
        /// Routes the filters took out.
        var hidden = 0

        var onlyBlockedRoutes: Bool { top.isEmpty && !more.isEmpty && more.allSatisfy(\.journey.isBlocked) }
        var mapJourneys: [Journey] { (onlyBlockedRoutes ? more : top).map(\.journey) }
    }

    /// Sources disagree by a minute or so; differences this small don't count.
    static let timeTolerance: TimeInterval = 60
    static let walkTolerance: TimeInterval = 120

    static func rank(_ journeys: [Journey], arriveBy: Bool, sort: SortOrder = .best, filter: RouteFilter = .init()) -> Ranked {
        let allowed = journeys.filter(filter.allows)
        let hidden = Set(journeys.map(\.routeSignature)).subtracting(allowed.map(\.routeSignature)).count

        let cost = { (journey: Journey) in score(journey, arriveBy: arriveBy, sort: sort) }
        let precedes = { (a: Journey, b: Journey) -> Bool in
            // A route through a reported closure goes after every one that isn't.
            if a.isBlocked != b.isBlocked { return !a.isBlocked }
            let (ca, cb) = (cost(a), cost(b))
            if ca != cb { return ca < cb }
            if a.departure != b.departure { return a.departure > b.departure }
            return a.routeSignature < b.routeSignature
        }
        let options = Dictionary(grouping: allowed, by: \.routeSignature).values
            .map { group in
                let sorted = group.sorted(by: precedes)
                let lead = sorted[0]
                // Leave times a minute or so apart are the same train, timed by different sources.
                var others: [Date] = []
                for departure in sorted.dropFirst().map(\.departure).sorted()
                where ([lead.departure] + others).allSatisfy({ abs($0.timeIntervalSince(departure)) >= 120 }) {
                    others.append(departure)
                }
                return RouteOption(journey: lead, otherDepartures: others,
                                   providers: ProviderID.allCases.filter { p in group.contains { $0.providers.contains(p) } })
            }
            .sorted { precedes($0.journey, $1.journey) }

        // A route earns a card if it's close to the best on the balanced score,
        // or on the chosen order's own terms. Switching order can bring routes
        // up (a direct one for "Fewest changes") but never hides the balanced picks.
        // Anything beaten outright on time, changes and walking stays under "more".
        let orders = sort == .best ? [SortOrder.best] : [.best, sort]
        let thresholds = orders.compactMap { order -> (SortOrder, Double)? in
            let cost = { (journey: Journey) in score(journey, arriveBy: arriveBy, sort: order) }
            guard let lead = options.filter({ !$0.journey.isBlocked }).min(by: { cost($0.journey) < cost($1.journey) }) else { return nil }
            return (order, cost(lead.journey) + max(10, lead.journey.duration / 60 * 0.35))
        }
        var ranked = Ranked(hidden: hidden)
        for option in options {
            // Only a route that should work can beat another; one through a closure never leads.
            let beaten = options.contains { !$0.journey.isBlocked && dominates($0.journey, option.journey, arriveBy: arriveBy) }
            let close = thresholds.contains { order, limit in score(option.journey, arriveBy: arriveBy, sort: order) <= limit }
            if option.journey.isBlocked || beaten || !close {
                ranked.more.append(option)
            } else {
                ranked.top.append(option)
            }
        }
        return ranked
    }

    /// Generalised cost in minutes: when you arrive (or, arriving by a deadline,
    /// how early you have to leave) plus what the changes and walking are worth.
    static func score(_ journey: Journey, arriveBy: Bool, sort: SortOrder) -> Double {
        let time = arriveBy ? -journey.departure.timeIntervalSinceReferenceDate : journey.arrival.timeIntervalSinceReferenceDate
        let weights = sort.weights
        return time / 60 + weights.change * Double(journey.changes) + weights.walkMinute * journey.walkingTime / 60
    }

    /// `a` is no worse than `b` on time, changes and walking, allowing for noise
    /// between sources, and clearly better on at least one.
    static func dominates(_ a: Journey, _ b: Journey, arriveBy: Bool) -> Bool {
        guard a.id != b.id else { return false }
        let timeGain = arriveBy ? a.departure.timeIntervalSince(b.departure) : b.arrival.timeIntervalSince(a.arrival)
        let walkGain = b.walkingTime - a.walkingTime
        let noWorse = timeGain >= -timeTolerance && a.changes <= b.changes && walkGain >= -walkTolerance
        let better = timeGain > timeTolerance || a.changes < b.changes || walkGain > walkTolerance
        return noWorse && better
    }
}
