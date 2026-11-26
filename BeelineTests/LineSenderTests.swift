import Intents
import Testing
import UIKit
import UserNotifications
@testable import Beeline

/// The line a notification comes from: what the alerts server sends (`sender` in
/// worker/src/push.ts) and the disc drawn from it.
struct LineSenderTests {
    @Test func readsTheServersSender() {
        let sender = LineSender(payload: ["id": "line:central", "name": "Central line", "color": "E32017", "symbol": "tram.fill"])
        #expect(sender == LineSender(id: "line:central", name: "Central line", color: "E32017", symbol: "tram.fill"))
        // National Rail has no line colour.
        #expect(LineSender(payload: ["id": "line:southeastern", "name": "Southeastern", "symbol": "train.side.front.car"])?.color == nil)
    }

    @Test func aPushWithoutOneShowsAsItCame() {
        #expect(LineSender(payload: nil) == nil)
        #expect(LineSender(payload: "Central line") == nil)
        #expect(LineSender(payload: ["id": "line:central", "symbol": "tram.fill"]) == nil, "no name")
        #expect(LineSender(payload: ["id": "", "name": "Central line", "symbol": "tram.fill"]) == nil)
        #expect(LineSender(payload: ["id": "line:central", "name": "Central line", "symbol": 7]) == nil)
    }

    @Test func theDiscIsTheLinesColourWithInkThatShows() throws {
        let central = LineSender(id: "line:central", name: "Central line", color: "E32017", symbol: "tram.fill")
        #expect(central.ink == .white)
        #expect(LineSender(id: "line:circle", name: "Circle line", color: "FFD300", symbol: "tram.fill").ink == .black, "pale lines take ink")
        #expect(LineSender(id: "x", name: "Southeastern", color: nil, symbol: "train.side.front.car").fill == .systemBlue)
        #expect(LineSender(id: "x", name: "Odd", color: "not-hex", symbol: "tram.fill").fill == .systemBlue)

        let image = try #require(UIImage(data: central.avatar(side: 90)))
        #expect(image.size == CGSize(width: 90, height: 90))
        // The corners are the line's colour (iOS cuts the circle); the train is in ink, in the middle.
        let disc = Self.pixels(image)
        let red: [UInt8] = [0xE3, 0x20, 0x17], white: [UInt8] = [0xFF, 0xFF, 0xFF]
        for corner in [0, 89, 90 * 89, 90 * 90 - 1] { #expect(disc[corner] == red) }
        let inked = disc.indices.filter { disc[$0] == white }
        #expect(inked.count > 300, "a train you can see")
        #expect(inked.allSatisfy { (15..<75).contains($0 % 90) && (15..<75).contains($0 / 90) }, "kept inside the circle")
        // A symbol this system doesn't have still gives the line's disc.
        let plain = try #require(UIImage(data: LineSender(id: "x", name: "X", color: "E32017", symbol: "no.such.symbol").avatar(side: 40)))
        #expect(Self.pixels(plain).allSatisfy { $0 == red })
    }

    /// What the notification extension does as an alert arrives: iOS takes the line as the sender
    /// and keeps the server's words and what a tap opens. It refuses without the Communication
    /// Notifications entitlement and `INSendMessageIntent` in the app's Info.plist.
    @Test func iOSShowsTheAlertAsFromTheLine() async throws {
        let content = UNMutableNotificationContent()
        content.title = "Central line"
        content.body = "Severe delays\nLeytonstone → Hainault"
        content.threadIdentifier = "alert-1"
        content.userInfo = ["alert": "alert-1"]
        let intent = LineSender(id: "line:central", name: "Central line", color: "E32017", symbol: "tram.fill").message(content.body)
        #expect(intent.sender?.displayName == "Central line")
        #expect(intent.sender?.image != nil)
        #expect(intent.conversationIdentifier == "line:central")
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        let shown = try content.updating(from: intent)
        #expect(shown.body == content.body)
        #expect(shown.threadIdentifier == "alert-1")
        #expect(shown.userInfo["alert"] as? String == "alert-1")
    }

    /// Each pixel's red, green and blue, row by row.
    private static func pixels(_ image: UIImage) -> [[UInt8]] {
        let width = image.cgImage!.width, height = image.cgImage!.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<$0 + 3]) }
    }
}
