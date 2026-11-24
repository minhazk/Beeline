import Foundation

/// What Go needs to pick a trip up again after Beeline was closed (swiped away, or put
/// down by iOS in the background): the journey as it now is, after any Switch, what
/// you've done, where you are in it and what the trip has asked. The boards, your fix
/// and the walk's route come back by themselves. No keys or settings go in here.
struct SavedTrip: Codable, Equatable, Sendable {
    /// Bumped when the shape changes; a file of another version is dropped.
    static let currentVersion = 1

    var version = SavedTrip.currentVersion
    var journey: Journey
    var query: JourneyQuery
    var legIndex: Int
    var log: TripLog
    var replanWatch: Replan.Watch
    /// Long waits a search found nothing better for.
    var checkedWaits: Set<String>
    /// When you'd get there, as the trip was going when this was saved.
    var arrival: Date
    /// The re-plan reason of a faster way on show when this was saved (the offer itself isn't
    /// kept): so "Keep my route" tapped on its notification after a relaunch still declines it.
    var offerKey: String? = nil

    /// Past the arrival by more than this, the trip is over: closed and never ended.
    static let staleAfter: TimeInterval = 30 * 60

    /// Still worth putting you back in Go: no more than half an hour past the arrival it had.
    func isResumable(now: Date) -> Bool {
        version == Self.currentVersion && !journey.legs.isEmpty && journey.legs.indices.contains(legIndex)
            && now <= arrival.addingTimeInterval(Self.staleAfter)
    }

    /// The same trip as far as saving goes: the arrival is saved only once it moves by
    /// five minutes or more, so a walk's estimate shifting by seconds writes nothing.
    func sameAs(_ other: SavedTrip) -> Bool {
        journey == other.journey && query == other.query && legIndex == other.legIndex && log == other.log
            && replanWatch == other.replanWatch && checkedWaits == other.checkedWaits && offerKey == other.offerKey
            && abs(arrival.timeIntervalSince(other.arrival)) < 5 * 60
    }
}

/// Where the live trip is kept between launches: one small JSON file,
/// `Application Support/Beeline/trip.json`, excluded from backups.
@MainActor
final class TripStore {
    static let shared = TripStore(url: TripStore.defaultURL())

    let url: URL

    init(url: URL) { self.url = url }

    static func defaultURL(in support: URL = .applicationSupportDirectory) -> URL {
        let folder = support.appending(path: "Beeline", directoryHint: .isDirectory)
        let previous = support.appending(path: "Polaris", directoryHint: .isDirectory)
        let files = FileManager.default
        if !files.fileExists(atPath: folder.path), files.fileExists(atPath: previous.path) {
            do {
                try files.moveItem(at: previous, to: folder)
            } catch {
                // Keep using the existing trip and retry the directory rename on the next launch.
                if !files.fileExists(atPath: folder.path) { return previous.appending(path: "trip.json") }
            }
        }
        return folder.appending(path: "trip.json")
    }

    func save(_ trip: SavedTrip) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The default date strategy keeps sub-second times, so a trip comes back exactly as it went.
            try JSONEncoder().encode(trip).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = url
            try? url.setResourceValues(values)
        } catch {
            // Losing the save loses only the resume, never the trip in front of you.
        }
    }

    /// The saved trip, or nil when there's none or it can't be read (a corrupt file, or
    /// one from an older shape).
    func load() -> SavedTrip? {
        guard let data = try? Data(contentsOf: url),
              let trip = try? JSONDecoder().decode(SavedTrip.self, from: data),
              trip.version == SavedTrip.currentVersion else { return nil }
        return trip
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What happens to a trip Beeline was closed during, decided once as it launches, before
/// anything can start a new trip or a new Live Activity.
@MainActor
enum TripResume {
    /// The trip to put you back in, until the map and sheet take it (`take`).
    private static var pending: SavedTrip?

    /// Keeps a trip still worth resuming for the sheet. Anything else (none saved, past its
    /// time, unreadable) is dropped along with what it left: the Live Activity is ended and
    /// Go's alerts, still to come or shown, are taken back.
    static func decide(store: TripStore = .shared, now: Date = .now, skip: Bool = false) {
        if !skip, let saved = store.load(), saved.isResumable(now: now) {
            pending = saved
            return
        }
        drop(store)
    }

    /// The trip for the sheet, once. Its age is checked again: launched in the background,
    /// Beeline may show its screen long after it decided.
    static func take(store: TripStore = .shared, now: Date = .now) -> SavedTrip? {
        guard let saved = pending else { return nil }
        pending = nil
        guard saved.isResumable(now: now) else {
            drop(store)
            return nil
        }
        return saved
    }

    private static func drop(_ store: TripStore) {
        held = nil
        store.clear()
        TripActivity.endLeftovers()
        TripAlerts.removeLeftovers()
    }

    /// Switch or Keep my route, tapped on a faster way's notification.
    enum OfferAction: Sendable { case keep, `switch` }
    /// Tapped while no trip was in memory (the tap opened Beeline cold): kept until the trip is back.
    private static var held: OfferAction?

    static func hold(_ action: OfferAction) { held = action }

    /// The tap, on the trip picked up again: Keep declines the reason that offer was for;
    /// Switch can't be done (the offer wasn't kept), so Go says it has gone.
    static func applyHeld(to trip: LiveTrip) {
        guard let action = held else { return }
        held = nil
        switch action {
        case .keep: trip.keepRoute()
        case .switch: trip.acceptOffer()
        }
    }
}
