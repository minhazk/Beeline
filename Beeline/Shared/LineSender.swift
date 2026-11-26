import Intents
import UIKit

/// Who a line alert's notification comes from: the line itself, as a disc in its colour with its
/// mode's train on it (a tick once it runs again), where the app icon would be. The alerts server
/// says who (`sender` in worker/src/push.ts); the notification extension draws the disc and hands
/// iOS the line as the sender. Compiled into the app (for its tests), the widget extension and
/// the notification extension.
struct LineSender: Equatable, Sendable {
    /// One conversation per line: "line:central".
    var id: String
    /// "Central line".
    var name: String
    /// Hex, as the Live Activity's attributes carry it; nil draws the app's blue.
    var color: String?
    /// SF Symbol: "tram.fill", "train.side.front.car", "checkmark".
    var symbol: String

    /// From a push's `sender`. Nil when it has none, or one this build can't read: the
    /// notification then shows as the server wrote it, beside the app icon.
    init?(payload: Any?) {
        guard let fields = payload as? [String: Any],
              let id = fields["id"] as? String, !id.isEmpty,
              let name = fields["name"] as? String, !name.isEmpty,
              let symbol = fields["symbol"] as? String, !symbol.isEmpty else { return nil }
        self.id = id
        self.name = name
        self.symbol = symbol
        color = fields["color"] as? String
    }

    init(id: String, name: String, color: String?, symbol: String) {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
    }

    /// The alert as a message from the line: what iOS needs to show the line's disc where the app
    /// icon would be, as it shows a person's picture on a message.
    func message(_ body: String) -> INSendMessageIntent {
        let person = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil, displayName: name,
                              image: INImage(imageData: avatar()), contactIdentifier: nil, customIdentifier: id)
        return INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: body,
                                   speakableGroupName: nil, conversationIdentifier: id, serviceName: nil, sender: person, attachments: nil)
    }

    /// The disc's colour: the line's, or the app's blue for a line without one (National Rail).
    var fill: UIColor {
        guard let color, color.count == 6, let value = UInt32(color, radix: 16) else { return .systemBlue }
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Pale lines (the Circle, the Hammersmith & City) take ink on top, not white.
    var ink: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        fill.getRed(&r, green: &g, blue: &b, alpha: nil)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 ? .black : .white
    }

    /// The disc as a PNG, `side` pixels across. iOS masks a sender's picture to a circle, so the
    /// colour runs to the corners and the symbol keeps to the middle.
    func avatar(side: CGFloat = 180) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { context in
            fill.setFill()
            context.fill(bounds)
            let weight = UIImage.SymbolConfiguration(pointSize: side * 0.56, weight: symbol == "checkmark" ? .bold : .semibold)
            // A symbol this system doesn't have leaves the plain disc: still the line's colour.
            guard let glyph = UIImage(systemName: symbol, withConfiguration: weight)?.withTintColor(ink, renderingMode: .alwaysOriginal) else { return }
            // Kept inside the circle iOS cuts, whatever the symbol's proportions.
            let room = side * 0.64, scale = min(1, room / max(glyph.size.width, glyph.size.height))
            let size = CGSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            glyph.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }
}
