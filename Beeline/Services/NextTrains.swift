import ActivityKit
import Foundation
import Observation
import os

/// The next-train Live Activity: the next few trains from one station on the Lock Screen,
/// started from a line near you, a departure board or a journey, or by the alerts server at a
/// saved line's travel times. One at a time: a new one takes the place of the last.
///
/// With an alerts server and a TfL line, the server keeps it up to date with live times while
/// Beeline is closed (worker/src/activities.ts). Otherwise it shows the timetable Beeline had,
/// refreshed each minute while Beeline is open.
@MainActor @Observable
final class NextTrains {
    static let shared = NextTrains()
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Beeline", category: "next-train")

    /// What's on the Lock Screen now: its key ("line:…", "leg:…", "alert:…").
    private(set) var showing: String?
    /// Why the last start didn't happen, for the button that asked.
    private(set) var problem: String?

    @ObservationIgnored private var watched = Set<String>()
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var resumed = false

    func isShowing(_ key: String) -> Bool { showing == key }

    /// What to show, and where it came from.
    struct Request: Sendable {
        var key: String
        var line: String
        var mode: LegMode
        var color: RGB?
        var stop: String
        var towards: String?
        /// For the alerts server, when TfL has the line.
        var follow: NextTrainAttributes.Follow?
        /// The departures Beeline has now, soonest first.
        var departures: [Departure]
        /// Fresh departures, for following without the server.
        var refresh: (@Sendable () async throws -> [Departure])?
        var ends: Date = .now.addingTimeInterval(90 * 60)

        var attributes: NextTrainAttributes {
            NextTrainAttributes(key: key, line: LinePill.shortName(line), symbol: mode.symbol, color: color?.hex, stop: stop,
                                towards: towards, follow: follow, ends: ends.timeIntervalSince1970)
        }
    }

    // MARK: Starting and stopping

    func start(_ request: Request) {
        problem = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            problem = "Live Activities are off for Beeline. Turn them on in Settings."
            return
        }
        stop()
        let state = Self.state(request.departures, live: false)
        let pushes = request.follow != nil && AlertStore.shared.isConfigured
        do {
            let activity = try Activity.request(attributes: request.attributes,
                                                content: ActivityContent(state: state, staleDate: state.staleDate(after: .now)),
                                                pushType: pushes ? .token : nil)
            showing = request.key
            watch(activity)
            if !pushes, let refresh = request.refresh { keepFresh(activity, with: refresh) }
            Self.log.notice("Started next-train Live Activity \(activity.id, privacy: .public)")
        } catch {
            problem = "Couldn't show it on the Lock Screen."
            Self.log.error("Next-train Live Activity refused: \(String(describing: error), privacy: .public)")
        }
    }

    /// Takes it off the Lock Screen, and tells the server to stop.
    func stop() {
        refreshing?.cancel()
        refreshing = nil
        showing = nil
        for activity in Activity<NextTrainAttributes>.activities {
            nonisolated(unsafe) let activity = activity
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: Launch

    /// At launch, in the background too (iOS wakes Beeline when the server starts one): pick up
    /// what's showing, register each new one's push token, and pass the push-to-start token on.
    func resume() {
        guard !resumed else { return }
        resumed = true
        for activity in Activity<NextTrainAttributes>.activities where [.active, .stale].contains(activity.activityState) {
            showing = activity.attributes.key
            watch(activity)
        }
        Task {
            for await activity in Activity<NextTrainAttributes>.activityUpdates {
                // Started by the server at a saved line's time: it replaces any other.
                for other in Activity<NextTrainAttributes>.activities where other.id != activity.id {
                    nonisolated(unsafe) let other = other
                    Task { await other.end(nil, dismissalPolicy: .immediate) }
                }
                showing = activity.attributes.key
                watch(activity)
            }
        }
        Task {
            for await token in Activity<NextTrainAttributes>.pushToStartTokenUpdates {
                AlertStore.shared.didGetStartToken(token.hex)
            }
        }
    }

    // MARK: Following one

    private func watch(_ activity: Activity<NextTrainAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        nonisolated(unsafe) let activity = activity
        let id = activity.id, key = activity.attributes.key
        Task {
            for await token in activity.pushTokenUpdates {
                await register(activity, token: token.hex)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                watched.remove(id)
                if showing == key, !Activity<NextTrainAttributes>.activities.contains(where: { $0.id != id && $0.attributes.key == key }) {
                    showing = nil
                    refreshing?.cancel()
                }
                if let token = activity.pushToken?.hex {
                    _ = try? await AlertStore.shared.sendToServer("DELETE", path: "activities/\(token)")
                }
                break
            }
        }
    }

    /// Hands the server the activity's push token and what it follows; shows its answer at once.
    private func register(_ activity: Activity<NextTrainAttributes>, token: String) async {
        guard let follow = activity.attributes.follow else { return }
        struct Body: Encodable { var environment: String; var follow: NextTrainAttributes.Follow; var ends: Double }
        struct Reply: Decodable { var state: NextTrainAttributes.ContentState? }
        do {
            let body = try JSONEncoder().encode(Body(environment: AlertStore.environment, follow: follow, ends: activity.attributes.ends))
            guard let data = try await AlertStore.shared.sendToServer("PUT", path: "activities/\(token)", body: body),
                  let state = try JSONDecoder().decode(Reply.self, from: data).state else { return }
            nonisolated(unsafe) let activity = activity
            await activity.update(ActivityContent(state: state, staleDate: state.staleDate(after: .now)))
        } catch {
            Self.log.error("Next-train registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Without the server: the timetable again each minute while Beeline is open.
    private func keepFresh(_ activity: Activity<NextTrainAttributes>, with refresh: @escaping @Sendable () async throws -> [Departure]) {
        nonisolated(unsafe) let activity = activity
        refreshing = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let departures = try? await refresh(), !Task.isCancelled else { continue }
                let state = Self.state(departures, live: false)
                await activity.update(ActivityContent(state: state, staleDate: state.staleDate(after: .now)))
            }
        }
    }

    nonisolated static func state(_ departures: [Departure], live: Bool, now: Date = .now) -> NextTrainAttributes.ContentState {
        let trains = departures
            .filter { $0.expected > now.addingTimeInterval(-15) }
            .sorted { $0.expected < $1.expected }
            .prefix(4)
            .map { departure in
                NextTrainAttributes.ContentState.Train(
                    at: (departure.isCancelled ? departure.scheduled : departure.expected).timeIntervalSince1970,
                    cancelled: departure.isCancelled,
                    late: departure.isLate && !departure.isCancelled ? Int((departure.delay / 60).rounded()) : nil)
            }
        return .init(trains: Array(trains), updated: now.timeIntervalSince1970, live: live || departures.contains { $0.isRealtime })
    }
}

// MARK: What to follow

extension NextTrains {
    /// Trains, the DLR and trams: what TfL and the timetables give next departures for by station.
    nonisolated static func follows(_ mode: LegMode) -> Bool {
        [.tube, .rail, .overground, .elizabeth, .dlr, .tram].contains(mode)
    }

    nonisolated static func key(for line: NearbyLine) -> String { "line:\(line.id)@\(line.stopName)" }
    nonisolated static func key(for leg: Leg) -> String { "leg:\(leg.line ?? leg.mode.rawValue)|\(leg.fromName)|\(leg.toName)" }

    /// A line near you: the trains with its headsign, from its nearest stop.
    static func request(for line: NearbyLine) async -> Request {
        let leg = Leg(mode: line.mode, line: line.line, lineColor: line.lineColor, headsign: line.headsign, fromName: line.stopName,
                      toName: line.headsign, departure: line.departures.first?.expected ?? .now, arrival: .now, path: [line.stopCoordinate])
        let id = line.id, at = line.stopCoordinate
        return Request(
            key: key(for: line), line: line.line, mode: line.mode, color: line.lineColor, stop: line.stopName,
            towards: line.headsign.isEmpty ? nil : line.headsign,
            follow: await follow(leg),
            departures: line.departures,
            refresh: { try await DepartureProvider().nearby(at).first { $0.id == id }?.departures ?? [] })
    }

    /// A ride on a journey or its board: the trains from where it boards that stop where it gets off.
    static func request(for leg: Leg, board: DepartureBoard?) async -> Request {
        let line = leg.line ?? leg.mode.label
        let sameLine: @Sendable (Departure) -> Bool = { leg.line == nil || Journey.normalise($0.line) == Journey.normalise(line) }
        let departures = board?.departures.filter(sameLine) ?? []
        return Request(
            key: key(for: leg), line: line, mode: leg.mode, color: leg.lineColor,
            stop: board?.stopName ?? leg.fromName, towards: leg.toName.isEmpty ? nil : leg.toName,
            follow: await follow(leg),
            departures: departures,
            refresh: { try await DepartureProvider().board(for: leg).departures.filter(sameLine) },
            ends: max(.now.addingTimeInterval(90 * 60), leg.departure.addingTimeInterval(30 * 60)))
    }

    /// TfL's line and stations for a ride, so the server can follow it; nil for lines TfL has no
    /// live times for (National Rail, buses) or stations it can't place.
    static func follow(_ leg: Leg) async -> NextTrainAttributes.Follow? {
        guard let lines = try? await TfLLines.lines(), let line = TfLLines.line(for: leg, in: lines),
              ["tube", "dlr", "elizabeth-line", "overground", "tram"].contains(line.mode),
              let route = try? await TfLLines.route(line.id),
              let from = route.station(named: leg.fromName), let to = route.station(named: leg.toName), from != to else { return nil }
        return .init(line: .init(id: line.id, name: line.name), mode: line.mode,
                     from: .init(id: from.id, name: from.name), to: .init(id: to.id, name: to.name))
    }
}

extension Data {
    /// A push token as APNs and the server spell it.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
