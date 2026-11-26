import Intents
import UserNotifications

/// Runs as a line alert arrives (the server marks those `mutable-content`), before it shows:
/// makes the line its sender, so iOS draws the line's disc where the app icon would be, as it
/// does a person's picture on a message. Anything that goes wrong shows the notification as the
/// server wrote it: the same words, beside the app icon.
final class NotificationService: UNNotificationServiceExtension {
    /// Held for `serviceExtensionTimeWillExpire`, which iOS calls on another thread if this takes
    /// too long; whichever of the two gets there first delivers, once.
    private let pending = Pending()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        nonisolated(unsafe) let deliver = contentHandler
        nonisolated(unsafe) let original = request.content
        pending.set { deliver(original) }
        guard let sender = LineSender(payload: original.userInfo["sender"]) else { return pending.finish() }

        let intent = sender.message(original.body)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        nonisolated(unsafe) let message = intent
        let pending = self.pending
        interaction.donate { _ in
            // Without the Communication Notifications entitlement this throws, and the original shows.
            guard let content = try? original.updating(from: message) else { return pending.finish() }
            nonisolated(unsafe) let updated = content
            pending.set { deliver(updated) }
            pending.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        pending.finish()
    }
}

/// What to deliver, delivered once, from whichever thread asks first.
private final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (() -> Void)?
    private var done = false

    func set(_ deliver: @escaping () -> Void) {
        lock.withLock { if !done { self.deliver = deliver } }
    }

    func finish() {
        let deliver = lock.withLock { () -> (() -> Void)? in
            guard !done else { return nil }
            done = true
            return self.deliver
        }
        deliver?()
    }
}
