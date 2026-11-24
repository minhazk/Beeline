import Foundation

/// TfL's published line colours, applied to every source's legs so the same
/// line looks the same whichever app found it.
enum LineColors {
    static let overgroundLines: Set<String> = ["liberty", "lioness", "mildmay", "suffragette", "weaver", "windrush"]

    private static let byLine: [String: String] = [
        "bakerloo": "B36305", "central": "E32017", "circle": "FFD300", "district": "00782A",
        "hammersmithandcity": "F3A9BB", "hammersmithcity": "F3A9BB", "jubilee": "A0A5A9",
        "metropolitan": "9B0056", "northern": "2B2B2B", "piccadilly": "1C3F94", "victoria": "0098D4",
        "waterlooandcity": "95CDBA", "waterloocity": "95CDBA",
        "elizabeth": "6950A1", "dlr": "00A4A7",
        "liberty": "61686B", "lioness": "FFA32B", "mildmay": "2E86F0", "suffragette": "59C274",
        "weaver": "A0457A", "windrush": "EF4D5E",
        "tram": "5FB526", "londontrams": "5FB526",
    ]

    private static let byMode: [LegMode: String] = [
        .bus: "DC241F", .coach: "B5651D", .tube: "1C3F94", .rail: "8A94A6", .overground: "EE7C0E",
        .elizabeth: "6950A1", .dlr: "00A4A7", .tram: "5FB526", .ferry: "0AA2DC", .cableCar: "C4122F",
        .other: "8A94A6",
    ]

    /// Normalised names of the lines with their own colours, for telling which
    /// line a status message is about.
    static var namedLines: [String] { Array(byLine.keys) }

    static func color(line: String?, mode: LegMode, providerHex: String? = nil) -> RGB? {
        if let line, let hex = byLine[Journey.normalise(line)] { return RGB(hex: hex) }
        if let provided = RGB(hex: providerHex) { return provided }
        return RGB(hex: byMode[mode])
    }
}
