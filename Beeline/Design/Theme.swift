import SwiftUI

/// Adaptive system surfaces and controls.
enum Theme {
    static let sheet = Color(uiColor: .systemGroupedBackground)
    static let group = Color(uiColor: .secondarySystemGroupedBackground)
    static let paper = Color(uiColor: .secondarySystemBackground)
    static let surface = Color(uiColor: .tertiarySystemBackground)
    static let ink = Color(uiColor: .label)
    static let tint = Color(uiColor: .systemBlue)
    static let hairline = Color(uiColor: .separator)
    static let live = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let casing = Color(uiColor: .systemBackground)

    /// Corner radius for grouped surfaces.
    static let radius: CGFloat = 18

    static func color(_ provider: ProviderID) -> Color {
        switch provider {
        case .google: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .tfl: Color(red: 0.86, green: 0.14, blue: 0.12)
        case .transitous: Color(red: 0.10, green: 0.60, blue: 0.40)
        case .apple: Color(uiColor: .systemGray)
        }
    }

    /// A line's colour for drawing it (on the map, down the itinerary). The
    /// Northern line's black disappears at night, so near-black lines lift to grey.
    static func line(_ color: RGB?) -> Color {
        guard let color else { return .gray }
        let own = UIColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        return color.luminance < 0.2 ? Color(uiColor: .systemGray2) : Color(uiColor: own)
    }

    /// Place names and the wordmark: New York, like an atlas's labels.
    static func title(_ style: Font.TextStyle = .title2) -> Font { .system(style, design: .serif).weight(.semibold) }
}

extension Color {
    init(_ rgb: RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b) }
}

extension View {
    /// A background for a group of rows or a distinct item.
    func surface(highlighted: Bool = false) -> some View {
        background(Theme.group, in: .rect(cornerRadius: Theme.radius))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(Theme.tint.opacity(0.55), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A four-pointed star with long north and south rays.
struct NorthStar: Shape {
    /// How fat the star is where its rays meet, as a share of its size.
    var waist: CGFloat = 0.09

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let v = rect.height / 2, h = rect.width / 2 * 0.72, waist = min(rect.width, rect.height) * waist
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - v))
        p.addQuadCurve(to: CGPoint(x: c.x + h, y: c.y), control: CGPoint(x: c.x + waist, y: c.y - waist))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + v), control: CGPoint(x: c.x + waist, y: c.y + waist))
        p.addQuadCurve(to: CGPoint(x: c.x - h, y: c.y), control: CGPoint(x: c.x - waist, y: c.y + waist))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - v), control: CGPoint(x: c.x - waist, y: c.y - waist))
        return p
    }
}

/// Beeline's mark: a north star whose four points each carry a smaller star,
/// and theirs smaller again. While a search runs, each of the four branches
/// stands for one source and fills in when that source answers.
struct FractalStar: View {
    var size: CGFloat = 28
    /// Branches drawn solid (north, east, south, west); the rest are outlines.
    var lit: [Bool] = [true, true, true, true]
    var color: Color = Theme.tint

    var body: some View {
        Canvas { context, canvas in
            let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            // The big star fills the middle; its children overhang to the edge.
            let radius = canvas.height / 2 / 1.52
            draw(&context, at: centre, radius: radius, depth: 0, lit: true)
            for (index, direction) in Self.directions.enumerated() {
                let tip = tipOffset(direction, radius: radius)
                draw(&context, at: CGPoint(x: centre.x + tip.x, y: centre.y + tip.y), radius: radius * 0.38,
                     depth: 1, lit: lit.indices.contains(index) ? lit[index] : true)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let directions: [CGPoint] = [CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)]

    private func tipOffset(_ direction: CGPoint, radius: CGFloat) -> CGPoint {
        // North and south rays are longer than east and west.
        let reach = direction.x == 0 ? radius : radius * 0.72
        return CGPoint(x: direction.x * reach, y: direction.y * reach)
    }

    private func draw(_ context: inout GraphicsContext, at centre: CGPoint, radius: CGFloat, depth: Int, lit: Bool) {
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let star = NorthStar(waist: 0.045).path(in: rect)
        if lit {
            context.fill(star, with: .color(color))
        } else {
            context.stroke(star, with: .color(color.opacity(0.45)), lineWidth: max(0.6, radius * 0.08))
        }
        guard depth < 2 else { return }
        for direction in Self.directions {
            let tip = tipOffset(direction, radius: radius)
            draw(&context, at: CGPoint(x: centre.x + tip.x, y: centre.y + tip.y), radius: radius * 0.34, depth: depth + 1, lit: lit)
        }
    }
}

extension Date {
    var clock: String { formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
}

extension TimeInterval {
    /// To the nearest minute. A length no journey has (not a number, or over a year) is none,
    /// since converting it to a whole number would stop the app.
    var wholeMinutes: Int {
        let minutes = (self / 60).rounded()
        return minutes.isFinite && abs(minutes) < 525_600 ? Int(minutes) : 0
    }

    /// "26 min", "1 h 05".
    var minutesText: String {
        let minutes = wholeMinutes
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// "+3 min", "−2 min", for comparing one time with another.
    var signedMinutesText: String {
        let minutes = wholeMinutes
        return minutes == 0 ? "same time" : minutes > 0 ? "+\(minutes) min" : "−\(-minutes) min"
    }
}
