@preconcurrency import UserNotifications

/// One timed nudge during a trip.
struct TripAlert: Equatable, Sendable {
    var id: String
    var date: Date
    var title: String
    var body: String
}

/// Where a trip's alerts go: the system's notification centre, or a test's list.
@MainActor protocol TripAlertScheduling: AnyObject {
    /// Makes these the trip's pending alerts, in place of any before.
    func schedule(_ alerts: [TripAlert])
    /// Removes every pending trip alert.
    func cancel()
    /// Shows a faster way now, with Switch and Keep my route; nil takes it back.
    func offer(_ message: Replan.Message?)
}

/// Timed nudges while a trip is live: when to leave, and when to get off. Timed
/// from the trip's re-timed timeline rather than GPS, because there is no fix
/// underground, and worked out again whenever that timeline moves.
@MainActor
enum TripAlerts {
    static let prefix = "trip."

    /// The alerts still to come, from the leg you're on, for the trip as it's going.
    /// A new one needs a little notice (`lead`); one already pending (`pending`) stays
    /// until its time, since dropping it moments early would mean it never fires.
    static func plan(_ timeline: TripTimeline, from index: Int, log: TripLog, destination: String, now: Date,
                     pending: Set<String> = []) -> [TripAlert] {
        let due = { (id: String, date: Date, lead: TimeInterval) in date > now.addingTimeInterval(pending.contains(id) ? 0 : lead) }
        let journey = timeline.journey
        var alerts: [TripAlert] = []
        for (offset, leg) in journey.legs.enumerated().dropFirst(index) where leg.mode.isTransit && log.ended[offset] == nil {
            let nextIndex = journey.legs.indices.dropFirst(offset + 1).first { journey.legs[$0].mode.isTransit }
            let then = nextIndex.map { next in
                let ride = journey.legs[next]
                let when = timeline.steps[next].isEstimate ? "" : " at \(ride.departure.clock)"
                return "Then the \(LinePill.shortName(ride.line ?? ride.mode.label))\(when) from \(ride.fromName)."
            } ?? "Then it's a short walk to \(destination)."
            // Long enough to get up and to the doors.
            let getOff = leg.arrival.addingTimeInterval(-90)
            if due("getoff.\(offset)", getOff, 30), leg.duration > 4 * 60 {
                alerts.append(TripAlert(id: "getoff.\(offset)", date: getOff, title: "Get off at \(leg.toName) next", body: then))
            }
        }
        // Started early: say when to set off for the first ride.
        if index == 0, log.ended[0] == nil, let walk = journey.legs.first, walk.mode == .walk,
           let ride = journey.legs.first(where: \.mode.isTransit), due("leave", journey.departure.addingTimeInterval(-60), 2 * 60) {
            alerts.append(TripAlert(id: "leave", date: journey.departure.addingTimeInterval(-60), title: "Time to leave",
                                    body: "Walk \(walk.duration.minutesText) to \(ride.fromName) for the \(ride.departure.clock) \(LinePill.shortName(ride.line ?? ride.mode.label))."))
        }
        return alerts
    }

    /// Worth sending again: a different set, or one moved by a minute or more.
    static func differ(_ a: [TripAlert], _ b: [TripAlert]) -> Bool {
        guard a.count == b.count else { return true }
        return zip(a, b).contains { x, y in
            x.id != y.id || x.title != y.title || x.body != y.body || abs(x.date.timeIntervalSince(y.date)) >= 60
        }
    }

    /// What to hand the notification centre: alerts still more than a second away.
    /// One due by the time it's handed over has been shown, or is about to be: adding it
    /// again would show it twice.
    nonisolated static func toAdd(_ alerts: [TripAlert], now: Date) -> [TripAlert] {
        alerts.filter { $0.date.timeIntervalSince(now) > 1 }
    }

    static var allIDs: [String] { (["leave"] + (0..<40).map { "getoff.\($0)" }).map { prefix + $0 } }

    /// A launch with no trip to pick up: the last trip's alerts, still to come or already
    /// shown, and its faster way, go. Only Go's own: your lines' alerts stay in Notification Centre.
    static func removeLeftovers() {
        let center = UNUserNotificationCenter.current()
        let ids = allIDs + [offerID]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

extension TripAlerts {
    nonisolated static let offerID = "trip.replan"
    nonisolated static let offerCategory = "replan"
    nonisolated static let switchAction = "replan.switch"
    nonisolated static let keepAction = "replan.keep"

    /// The offer's buttons, registered once at launch.
    nonisolated static var offerActions: UNNotificationCategory {
        UNNotificationCategory(identifier: offerCategory, actions: [
            UNNotificationAction(identifier: switchAction, title: "Switch", options: [.foreground]),
            UNNotificationAction(identifier: keepAction, title: "Keep my route", options: []),
        ], intentIdentifiers: [])
    }
}

/// Trip alerts as local notifications. Changes go one after another, so an End
/// straight after a re-time can't leave alerts behind it; permission is asked once.
@MainActor
final class SystemTripAlerts: TripAlertScheduling {
    private var queue: Task<Void, Never>?
    private var authorised: Bool?

    func schedule(_ alerts: [TripAlert]) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.apply(alerts)
        }
    }

    func cancel() {
        let previous = queue
        let ids = TripAlerts.allIDs
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        queue = Task {
            await previous?.value
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func offer(_ message: Replan.Message?) {
        // Taken back straight away, not queued: End releases the trip (and this) at once.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [TripAlerts.offerID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [TripAlerts.offerID])
        guard message != nil else { return }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.show(message)
        }
    }

    /// Ordinary, not Time Sensitive: a suggestion, not a warning.
    private func show(_ message: Replan.Message?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [TripAlerts.offerID])
        center.removeDeliveredNotifications(withIdentifiers: [TripAlerts.offerID])
        guard let message else { return }
        if authorised == nil {
            authorised = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        }
        guard authorised == true else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.detail
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = TripAlerts.offerCategory
        try? await center.add(UNNotificationRequest(identifier: TripAlerts.offerID, content: content, trigger: nil))
    }

    private func apply(_ alerts: [TripAlert]) async {
        let center = UNUserNotificationCenter.current()
        if authorised == nil {
            authorised = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        }
        guard authorised == true else { return }
        center.removePendingNotificationRequests(withIdentifiers: TripAlerts.allIDs)
        for alert in TripAlerts.toAdd(alerts, now: .now) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.interruptionLevel = .active
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.date.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: TripAlerts.prefix + alert.id, content: content, trigger: trigger))
        }
    }
}

/// Shows trip alerts as banners even with Beeline open, since the phone is
/// often in a pocket with the app still in front.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // With Beeline open, a faster way is already the card in Go's sheet: no banner over it.
        if notification.request.content.categoryIdentifier == TripAlerts.offerCategory { return [] }
        // Kept in Notification Centre too: a closure seen as a banner is still there later.
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == TripAlerts.offerCategory {
            let action = response.actionIdentifier
            await MainActor.run {
                // Opened cold by the tap: the trip isn't back yet, so the tap waits for it (`TripResume`).
                let tapped: TripResume.OfferAction? = action == TripAlerts.switchAction ? .switch : action == TripAlerts.keepAction ? .keep : nil
                guard let tapped else { return }
                if let trip = LiveTrip.current {
                    tapped == .keep ? trip.keepRoute() : trip.acceptOffer()
                } else {
                    TripResume.hold(tapped)
                }
            }
            return
        }
        guard response.notification.request.content.userInfo["alert"] is String else { return }
        await MainActor.run { AlertStore.shared.showAlerts = true }
    }
}
