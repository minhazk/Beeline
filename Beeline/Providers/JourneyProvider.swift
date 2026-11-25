import Foundation

protocol JourneyProvider: Sendable {
    var id: ProviderID { get }
    /// `deep` fans the query out over the provider's preference variants
    /// (fewer changes, less walking, mode filters) to surface routes its
    /// default ranking hides.
    func journeys(for query: JourneyQuery, deep: Bool) async throws -> [Journey]
}

/// Runs every query variant concurrently. One failing variant doesn't sink the
/// rest; only if all fail is the first error thrown.
func fanOut<V: Sendable>(_ variants: [V], _ fetch: @escaping @Sendable (V) async throws -> [Journey]) async throws -> [Journey] {
    let results = await withTaskGroup(of: Result<[Journey], any Error>.self) { group in
        for variant in variants {
            group.addTask {
                do { return .success(try await fetch(variant)) } catch { return .failure(error) }
            }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    var journeys: [Journey] = []
    var firstError: (any Error)?
    var succeeded = false
    for result in results {
        switch result {
        case .success(let found): journeys += found; succeeded = true
        case .failure(let error): firstError = firstError ?? error
        }
    }
    if !succeeded, let firstError { throw firstError }
    return journeys
}

enum ProviderError: LocalizedError, Equatable {
    case missingKey
    case http(Int)
    case noRoutes
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key"
        case .http(429): "Rate limited"
        case .http(401), .http(403): "Key rejected"
        case .http(let code): "HTTP \(code)"
        case .noRoutes: "No routes"
        case .badResponse: "Unreadable response"
        }
    }
}

enum HTTP {
    static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let appUserAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Beeline/\(version) (iOS transit app)"
    }()

    static func userAgent(for url: URL?) -> String {
        guard let host = url?.host()?.lowercased(), ["api.transitous.org", "api.tfl.gov.uk"].contains(host) else {
            return appUserAgent
        }
        let builtIn = Bundle.main.object(forInfoDictionaryKey: "BeelineContact") as? String
        guard let contact = builtIn.flatMap(Contact.valid) else { return appUserAgent }
        return "\(appUserAgent) (\(contact))"
    }

    static func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(userAgent(for: request.url), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await privateSession.data(for: request, delegate: ProviderRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw ProviderError.badResponse
        }
    }
}

/// Provider redirects may retain a query, request body or API-key header.
final class ProviderRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ProviderRedirects()

    static func permits(from: URL?, to: URL?) -> Bool {
        guard let from, let to, from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "https",
              let host = from.host()?.lowercased(), host == to.host()?.lowercased(),
              to.user() == nil, to.password() == nil else { return false }
        return (from.port ?? 443) == (to.port ?? 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.permits(from: task.originalRequest?.url, to: request.url) ? request : nil
    }
}

enum Time {
    static let london = TimeZone(identifier: "Europe/London")!

    /// RFC 3339 with or without fractional seconds.
    static func iso(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let d = try? Date(string, strategy: .iso8601) { return d }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func isoString(_ date: Date) -> String { date.formatted(.iso8601) }

    /// TfL's zone-less "2026-10-28T12:07:00", which is London wall-clock time.
    static func londonLocal(_ string: String?) -> Date? {
        guard let string else { return nil }
        let parts = string.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4],
            second: parts.count > 5 ? parts[5] : 0))
    }

    static func londonComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}

enum Polyline {
    /// Google's encoded polyline format; Google uses precision 5, MOTIS 6 (or 7).
    static func decode(_ encoded: String, precision: Int = 5) -> [Coordinate] {
        guard (0...9).contains(precision) else { return [] }
        let factor = pow(10.0, Double(precision))
        var coordinates: [Coordinate] = []
        var index = encoded.unicodeScalars.startIndex
        let scalars = encoded.unicodeScalars
        var lat = 0, lon = 0

        func next() -> Int? {
            var result = 0, shift = 0
            // Forty bits cover a longitude delta across the globe at precision nine.
            while index < scalars.endIndex, shift <= 35 {
                let byte = Int(scalars[index].value) - 63
                guard (0...63).contains(byte) else { return nil }
                index = scalars.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }

        while index < scalars.endIndex {
            guard let dLat = next(), let dLon = next() else { return [] }
            lat += dLat
            lon += dLon
            let point = Coordinate(latitude: Double(lat) / factor, longitude: Double(lon) / factor)
            guard (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else { return [] }
            coordinates.append(point)
        }
        return coordinates
    }
}

extension LegMode {
    /// Sources describe the Elizabeth line, DLR and Overground as generic rail or
    /// subway; their names say which they really are.
    func refined(line: String?, agency: String?) -> LegMode {
        let text = "\(line ?? "") \(agency ?? "")".lowercased()
        if text.contains("elizabeth") { return .elizabeth }
        if text.contains("dlr") || text.contains("docklands") { return .dlr }
        if text.contains("overground") { return .overground }
        if let line, LineColors.overgroundLines.contains(Journey.normalise(line)) { return .overground }
        if text.contains("london underground"), self == .rail { return .tube }
        return self
    }
}
