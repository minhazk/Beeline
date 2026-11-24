import Foundation

/// What a re-plan's search came back with.
struct ReplanAnswer: Sendable {
    var journeys: [Journey]
    /// At least one source replied.
    var answered: Bool
    var usedGoogle: Bool
    /// TfL's network status was had, so the journeys carry its notices.
    var statusChecked = true
}

/// A re-plan's one search: Google once (while the allowance and the trip's cap allow), TfL
/// once, Transitous once, never their deep-search variants, plus TfL's network status (shared
/// with searches, kept 3 minutes) to flag what comes back. At most 5 requests.
@MainActor
enum ReplanSearch {
    typealias Search = @MainActor (JourneyQuery, Replan.Watch) async -> ReplanAnswer

    static func live(settings: AppSettings, usage: GoogleUsage = .shared) -> Search {
        { query, watch in
            let now = Date.now
            let enabled = Set(ProviderID.allCases.filter(settings.isEnabled))
            let sources = Replan.sources(enabled: enabled, hasGoogleKey: settings.googleKey != nil,
                                         allowance: usage.allowance, watch: watch, now: now)
            var providers: [any JourneyProvider] = []
            if sources.contains(.google) {
                usage.spend(1, now: now)
                providers.append(GoogleRoutesProvider(apiKey: settings.googleKey, maxRequests: 1))
            }
            if sources.contains(.tfl) { providers.append(TfLProvider(appKey: settings.tflKey)) }
            if sources.contains(.transitous) { providers.append(TransitousProvider()) }
            let tflKey = settings.tflKey
            let checksNetwork = enabled.contains(.tfl)

            async let network: NetworkStatus? = checksNetwork ? SearchModel.networkStatus(appKey: tflKey) : nil
            let results = await withTaskGroup(of: [Journey]?.self) { group in
                for provider in providers {
                    group.addTask {
                        do { return try await provider.journeys(for: query, deep: false) }
                        catch ProviderError.noRoutes { return [] }
                        catch { return nil }
                    }
                }
                var all: [[Journey]?] = []
                for await result in group { all.append(result) }
                return all
            }
            let status = await network
            let journeys = JourneyMerger.merge(results.compactMap { $0 }.flatMap { $0 }).map { journey in
                var journey = journey
                if let status { journey.notices = status.notices(for: journey) }
                return journey
            }
            // Without TfL's status the offer still goes, saying it wasn't checked (TfL off counts too).
            return ReplanAnswer(journeys: journeys, answered: results.contains { $0 != nil }, usedGoogle: sources.contains(.google),
                                statusChecked: status != nil)
        }
    }
}
