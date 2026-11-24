import Foundation
import Testing
@testable import Beeline

/// The alerts server: which addresses pass, and that a token only goes with its own address.
struct AlertServerTests {
    @Test func httpsAddressesPass() throws {
        #expect(try AlertServer.address("https://alerts.example.com").absoluteString == "https://alerts.example.com")
        #expect(try AlertServer.address("  https://alerts.example.com/ ").absoluteString == "https://alerts.example.com", "trimmed, no trailing slash")
        #expect(try AlertServer.address("https://example.com/beeline").absoluteString == "https://example.com/beeline")
        #expect(try AlertServer.address("HTTPS://Alerts.Example.com:8443").host() == "alerts.example.com")
        // One spelling per server, so one device secret: case, default port and trailing slash.
        let forms = ["https://alerts.example.com", "HTTPS://ALERTS.example.com", "https://alerts.example.com:443/", "https://alerts.example.com//"]
        #expect(Set(try forms.map { try AlertServer.address($0).absoluteString }) == ["https://alerts.example.com"])
        #expect(try AlertServer.address("http://localhost:80").absoluteString == "http://localhost")
        #expect(try AlertServer.address("https://example.com/Beeline").absoluteString == "https://example.com/Beeline", "the path is kept as typed")
    }

    @Test func plainHTTPOnlyForThisMac() throws {
        #expect(try AlertServer.address("http://localhost:8787").port == 8787)
        #expect(try AlertServer.address("http://127.0.0.1:8787").host() == "127.0.0.1")
        #expect(throws: AlertServer.Problem.notHTTPS) { try AlertServer.address("http://alerts.example.com") }
        #expect(throws: AlertServer.Problem.notHTTPS) { try AlertServer.address("http://192.168.1.5:8787") }
    }

    @Test func otherShapesFail() {
        for text in ["", "alerts.example.com", "ftp://alerts.example.com", "https://", "https://alerts.example.com?x=1", "https://alerts.example.com/#a", "javascript:alert(1)"] {
            #expect(throws: AlertServer.Problem.self, "\(text)") { try AlertServer.address(text) }
        }
        #expect(throws: AlertServer.Problem.hasCredentials) { try AlertServer.address("https://me:secret@alerts.example.com") }
    }

    @Test func enteredServerWinsAndNeedsItsOwnToken() {
        let builtIn = AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: "https://built.example.com", builtInToken: "built-token")
        #expect(builtIn == AlertServer(url: URL(string: "https://built.example.com")!, token: "built-token", isBuiltIn: true))

        let entered = AlertServer.resolve(enteredURL: "https://mine.example.com", enteredToken: "mine", builtInURL: "https://built.example.com", builtInToken: "built-token")
        #expect(entered?.url.host() == "mine.example.com")
        #expect(entered?.token == "mine")
        #expect(entered?.isBuiltIn == false)

        // An address with no token of its own never borrows the built-in one.
        #expect(AlertServer.resolve(enteredURL: "https://mine.example.com", enteredToken: " ", builtInURL: "https://built.example.com", builtInToken: "built-token") == nil)
        // Nor does a bad entered address fall back to the built-in server.
        #expect(AlertServer.resolve(enteredURL: "http://mine.example.com", enteredToken: "mine", builtInURL: "https://built.example.com", builtInToken: "built-token") == nil)
    }

    @Test func nothingSetIsOff() {
        #expect(AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: "", builtInToken: "") == nil)
        #expect(AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: nil, builtInToken: nil) == nil)
        #expect(AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: "https://built.example.com", builtInToken: "") == nil, "an address without its token is off")
        // An xcconfig line written https://… is cut at the "//": what's left must not pass.
        #expect(AlertServer.resolve(enteredURL: "", enteredToken: "", builtInURL: "https:", builtInToken: "t") == nil)
    }

    @Test func eachAddressHasItsOwnSecret() {
        let home = URL(string: "https://built.example.com")!
        let builtIn = AlertServer(url: home, token: "t", isBuiltIn: true)
        let typed = AlertServer(url: home, token: "other", isBuiltIn: false)
        #expect(builtIn.secretAccount == typed.secretAccount, "the same server, built in or entered, keeps its secret")
        let a = AlertServer(url: URL(string: "https://a.example.com")!, token: "t", isBuiltIn: false)
        #expect(a.secretAccount != builtIn.secretAccount)
        #expect(a.secretAccount.hasPrefix("alerts.secret."))
        #expect(builtIn.secretAccount != AlertServer.legacySecretAccount)
    }

    @Test func label() {
        #expect(AlertServer(url: URL(string: "https://alerts.example.com")!, token: "t", isBuiltIn: false).label == "alerts.example.com")
        #expect(AlertServer(url: URL(string: "http://localhost:8787")!, token: "t", isBuiltIn: false).label == "localhost:8787")
    }
}
