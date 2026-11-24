import Foundation
import Observation

enum ProviderStatus: Equatable {
    case loading
    case done(Int)
    case failed(String)
    case off(String)
}

/// One search across every enabled source. Results merge in as each source
/// answers, so the fast ones show while the slow ones are still working.
@MainActor @Observable
final class SearchModel {
    private(set) var query: JourneyQuery?
    private(set) var statuses: [ProviderID: ProviderStatus] = [:]
    /// Every source's journeys, merged; the view ranks them by the chosen order.
    private(set) var journeys: [Journey] = []
    private(set) var appleEstimate: AppleEstimate?
    /// TfL's reports on the network, checked against every source's journeys.
    private(set) var network: NetworkStatus?
    private var found: [Journey] = []
    private var task: Task<Void, Never>?
    private let usage: GoogleUsage

    init(usage: GoogleUsage = .shared) { self.usage = usage }

    /// The network's status is the same for every search for a few minutes.
    private static var cachedNetwork: (at: Date, status: NetworkStatus)?
    static let networkFreshFor: TimeInterval = 3 * 60

    var isSearching: Bool { statuses.values.contains(.loading) }

    func search(_ query: JourneyQuery, settings: AppSettings) {
        task?.cancel()
        self.query = query
        found = []
        journeys = []
        appleEstimate = nil
        network = nil
        statuses = [:]

        // Google within its free monthly allowance: every deep-search way under 700 this month,
        // one under 900, none past that.
        let google = Self.googlePlan(enabled: settings.isEnabled(.google), hasKey: settings.googleKey != nil,
                                     deep: settings.deepSearch, allowance: usage.allowance, now: .now)
        let googleRequests = if case .ask(let n) = google { n } else { 0 }
        let providers: [any JourneyProvider] = [
            GoogleRoutesProvider(apiKey: settings.googleKey, maxRequests: googleRequests),
            TfLProvider(appKey: settings.tflKey),
            TransitousProvider(),
        ]
        for provider in providers {
            if provider.id == .google, case .off(let why) = google { statuses[provider.id] = .off(why) }
            else if !settings.isEnabled(provider.id) { statuses[provider.id] = .off("Turned off") }
            else { statuses[provider.id] = .loading }
        }
        if statuses[.google] == .loading { usage.spend(googleRequests) }
        statuses[.apple] = settings.isEnabled(.apple) ? .loading : .off("Turned off")

        let deep = settings.deepSearch
        let checksNetwork = settings.isEnabled(.tfl)
        let tflKey = settings.tflKey
        let active = providers.filter { statuses[$0.id] == .loading }
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                for provider in active {
                    group.addTask {
                        let result: Result<[Journey], any Error>
                        do { result = .success(try await provider.journeys(for: query, deep: deep)) } catch { result = .failure(error) }
                        await self.receive(result, from: provider.id)
                    }
                }
                if statuses[.apple] == .loading {
                    group.addTask { await self.estimateWithApple(query) }
                }
                if checksNetwork {
                    group.addTask { await self.loadNetwork(appKey: tflKey) }
                }
            }
        }
    }

    private func receive(_ result: Result<[Journey], any Error>, from provider: ProviderID) {
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let new):
            found += new
            publish()
            statuses[provider] = .done(new.count)
        case .failure(let error):
            statuses[provider] = .failed(Self.describe(error))
        }
    }

    private func publish() {
        let merged = JourneyMerger.merge(found)
        guard let network else {
            journeys = merged
            return
        }
        journeys = merged.map { journey in
            var journey = journey
            journey.notices = network.notices(for: journey)
            return journey
        }
    }

    private func loadNetwork(appKey: String?) async {
        // Without it the routes still show, just unchecked.
        guard let status = await Self.networkStatus(appKey: appKey), !Task.isCancelled else { return }
        network = status
        publish()
    }

    enum GooglePlan: Equatable, Sendable { case ask(Int), off(String) }
    /// What a search asks Google: every deep-search way under 700 this month, one under 900, none past.
    nonisolated static func googlePlan(enabled: Bool, hasKey: Bool, deep: Bool, allowance: GoogleAllowance, now: Date) -> GooglePlan {
        guard enabled else { return .off("Turned off") }
        guard hasKey else { return .off("Add a key in Settings") }
        let requests = allowance.searchRequests(deep: deep, variants: GoogleRoutesProvider.variants.count, now: now)
        return requests > 0 ? .ask(requests) : .off("Free allowance used this month")
    }

    /// TfL's network status, shared by searches and re-plans: two requests, kept 3 minutes.
    static func networkStatus(appKey: String?) async -> NetworkStatus? {
        if let cached = cachedNetwork, Date.now.timeIntervalSince(cached.at) < networkFreshFor { return cached.status }
        guard let status = try? await NetworkStatus.fetch(appKey: appKey) else { return nil }
        cachedNetwork = (.now, status)
        return status
    }

    private func estimateWithApple(_ query: JourneyQuery) async {
        do {
            let estimate = try await AppleEstimator.estimate(query)
            guard !Task.isCancelled else { return }
            appleEstimate = estimate
            statuses[.apple] = .done(1)
        } catch {
            guard !Task.isCancelled else { return }
            statuses[.apple] = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? ProviderError { return error.errorDescription ?? "Failed" }
        if (error as? URLError)?.code == .notConnectedToInternet { return "Offline" }
        if (error as? URLError)?.code == .timedOut { return "Timed out" }
        return "No routes"
    }
}
