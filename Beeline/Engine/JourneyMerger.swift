import Foundation

/// Folds every source's copy of the same journey into one, keeping all their badges.
enum JourneyMerger {
    /// Same lines boarding within this window are the same journey.
    static let sameDepartureWindow: TimeInterval = 4 * 60

    static func merge(_ journeys: [Journey]) -> [Journey] {
        var merged: [Journey] = []
        let ordered = journeys.sorted { ($0.sources.first?.provider.mergePriority ?? 9) < ($1.sources.first?.provider.mergePriority ?? 9) }
        for journey in ordered {
            if let i = merged.firstIndex(where: { isSame($0, journey) }) {
                for tag in journey.sources where !merged[i].sources.contains(tag) { merged[i].sources.append(tag) }
                merged[i].fare = merged[i].fare ?? journey.fare
                merged[i].hasDisruption = merged[i].hasDisruption || journey.hasDisruption
            } else {
                merged.append(journey)
            }
        }
        return merged
    }

    static func isSame(_ a: Journey, _ b: Journey) -> Bool {
        a.routeSignature == b.routeSignature && abs(a.firstBoarding.timeIntervalSince(b.firstBoarding)) <= sameDepartureWindow
    }
}
