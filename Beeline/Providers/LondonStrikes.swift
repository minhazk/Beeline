import Foundation

/// A strike window, distinct from TfL's line-level descriptions of its impact.
struct LondonStrike: Identifiable, Sendable {
    var id: String
    var title: String
    var mode: String
    var start: Date?
    var end: Date?
    var details: Set<String> = []
    var lines: Set<String> = []
    var publishedDate = false
    var datePending = false

    var isTube: Bool { mode == "tube" }
}

struct LondonStrikeBoard: Sendable {
    var checked: Date
    var events: [LondonStrike]
    var warnings: [String]
    var checkingForecast = false
}

enum LondonStrikes {
    static let guidance = URL(string: "https://tfl.gov.uk/status-updates/strikes")!
    static let modes = ["bus": "London buses", "cable-car": "London Cable Car", "dlr": "DLR",
                        "elizabeth-line": "Elizabeth line", "national-rail": "National Rail", "overground": "London Overground",
                        "river-bus": "River Bus", "tram": "London Trams", "tube": "Tube"]
    struct Line: Decodable, Sendable {
        let id, name, modeName: String
        let lineStatuses: [Status]
    }
    struct Status: Decodable, Sendable {
        let statusSeverityDescription: String?
        let reason: String?
        let validityPeriods: [Period]?
        let disruption: Disruption?
        struct Period: Decodable, Sendable { let fromDate, toDate: String? }
        struct Disruption: Decodable, Sendable { let description: String? }
    }

    private static let networkHeadings = [
        ("tube", #"\b(tube|underground)\b"#), ("elizabeth-line", #"\belizabeth line\b"#),
        ("dlr", #"\b(dlr|docklands light railway)\b"#), ("tram", #"\btrams?\b"#),
        ("cable-car", #"\bcable car\b"#)
    ]
    static func publishedMode(_ title: String) -> String {
        let headings = networkHeadings + [("river-bus", #"\b(river bus|ferry)\b"#), ("bus", #"\b(bus|buses)\b"#),
                                         ("overground", #"\boverground\b"#), ("national-rail", #"\b(rail|railway|trains?)\b"#)]
        return headings.first { title.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil }?.0 ?? "bulletin"
    }

    private static func matchesPublished(_ event: LondonStrike, notice: LondonStrike) -> Bool {
        guard event.mode == notice.mode || event.mode == "bulletin" else { return false }
        if networkHeadings.contains(where: { $0.0 == event.mode }) { return true }
        // A shared date or a generic bus heading does not identify an operator.
        let generic = Set("the of on at by and london bus buses drivers driver s staff workers services service rail national railway train trains river overground strike strikes industrial action walkout walkouts planned".split(separator: " "))
        let operatorWords = Set(event.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })).subtracting(generic)
        let report = (notice.details.union(notice.lines)).joined(separator: " ").lowercased()
        return !operatorWords.isEmpty && operatorWords.isSubset(of: Set(report.split(whereSeparator: { !$0.isLetter && !$0.isNumber })))
    }

    static func isAction(_ text: String) -> Bool {
        let words = text.replacingOccurrences(of: #"\b(lightning|bridge|bird|object|vehicle) strikes?\b|\bstrikes? (a|the) (bridge|vehicle|train|bus)\b"#,
                                               with: "", options: [.caseInsensitive, .regularExpression])
        let action = #"\b(strikes?(?: action)?|industrial action|walk[ -]?outs?|overtime ban)\b"#
        guard words.range(of: action, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        let withdrawn = #"called off|cancelled|suspended|averted|postponed|ended|will not (?:go ahead|take place)|no longer (?:going ahead|taking place)"#
        let cancelled = action + #"(?:(?!\b(?:trains?|services?|buses|departures?)\b)[^.!?;:]){0,100}\b(?:"# + withdrawn + #")\b|\b(?:called off|averted|cancelled|postponed|no) (?:the |their |planned |further )*"# + action
        return words.range(of: cancelled, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func notices(_ lines: [Line], now: Date, live: Bool) -> [LondonStrike] {
        var result: [LondonStrike] = []
        for line in lines {
            guard let network = modes[line.modeName] else { continue }
            for status in line.lineStatuses {
                let reason = [status.reason, status.disruption?.description, status.statusSeverityDescription]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                guard isAction(reason + ". " + (status.statusSeverityDescription ?? "")) else { continue }
                let periods = status.validityPeriods ?? []
                let name = line.modeName == "bus" ? "Route " + line.name : line.name
                let labels = [line.name, name, line.name + " line"]
                let parts = reason.split(separator: ":", maxSplits: 1)
                let text = parts.count == 2 && labels.contains(where: { $0.caseInsensitiveCompare(String(parts[0])) == .orderedSame })
                    ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : reason
                let scope = line.modeName == "national-rail" ? line.id : line.modeName
                func event(_ start: Date?, _ end: Date?, datePending: Bool = false) -> LondonStrike {
                    let active = start.map { $0 <= now } ?? true
                    // Live status periods describe individual updates. Do not present these as the
                    // hours of industrial action or merge unrelated actions that happen together.
                    let key = datePending ? "undated" : active ? "live" : "\(start!.timeIntervalSince1970)/\(end!.timeIntervalSince1970)"
                    return LondonStrike(id: "\(scope)/\(key)/\(text.lowercased())", title: line.modeName == "bus" ? "London bus strike" : network + " strike",
                                        mode: line.modeName, start: active && live ? nil : start, end: active && live ? nil : end,
                                        details: [reason], lines: [name], datePending: datePending)
                }
                if periods.isEmpty {
                    let planned = reason.range(of: #"\b(planned|proposed|upcoming|planning|announced|may take place)\b"#,
                                               options: [.regularExpression, .caseInsensitive]) != nil
                    // The dated endpoint sometimes echoes an undated live report. Only a
                    // prospective bulletin without dates belongs in “Dates to confirm”.
                    if live || planned { result.append(event(nil, nil, datePending: planned)) }
                }
                for period in periods {
                    guard let start = Time.iso(period.fromDate), let end = Time.iso(period.toDate),
                          start <= end, end >= now, live || start > now else { continue }
                    result.append(event(start, end))
                }
            }
        }
        return result
    }

    static func board(current: [Line], forecast: [Line], calendar: [LondonStrike], now: Date, warnings: [String]) -> LondonStrikeBoard {
        var entries = Dictionary(calendar.filter { ($0.end ?? .distantFuture) >= now }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let notices = notices(current, now: now, live: true) + notices(forecast, now: now, live: false)
        for notice in notices {
            let windows = calendar.filter { event in
                guard !notice.datePending, matchesPublished(event, notice: notice), let start = event.start, let end = event.end else { return false }
                return notice.start.map { $0 == start && notice.end == end } ?? (start <= now && now <= end)
            }
            let window = windows.count == 1 ? windows[0] : nil
            let key = window?.id ?? notice.id
            if entries[key] != nil {
                entries[key]?.lines.formUnion(notice.lines)
                entries[key]?.details.formUnion(notice.details)
            } else { entries[key] = notice }
        }
        let sorted = entries.values.sorted {
            if $0.start != $1.start { return ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
            return $0.id < $1.id
        }
        return LondonStrikeBoard(checked: now, events: sorted, warnings: warnings)
    }

    static func fetch(key: String?, now: Date = .now,
                      onLive: (@MainActor @Sendable (LondonStrikeBoard) -> Void)? = nil) async throws -> LondonStrikeBoard {
        func request(_ path: String) -> URLRequest {
            var url = URLComponents(string: "https://api.tfl.gov.uk/Line/" + path)!
            url.queryItems = [URLQueryItem(name: "detail", value: "false")]
            if let key, !key.isEmpty { url.queryItems?.append(URLQueryItem(name: "app_key", value: key)) }
            return URLRequest(url: url.url!)
        }
        @Sendable func read(_ request: URLRequest) async throws -> [Line] {
            try JSONDecoder().decode([Line].self, from: await HTTP.data(for: request))
        }
        async let bulletin = try? HTTP.data(for: URLRequest(url: guidance))
        let current = try? await read(request("Mode/" + modes.keys.sorted().joined(separator: ",") + "/Status"))
        try Task.checkCancellation()
        let published = await bulletin.flatMap { StrikeCalendar.parse(String(decoding: $0, as: UTF8.self)) }
        guard current?.isEmpty == false || published != nil else { throw URLError(.cannotLoadFromNetwork) }

        var warnings: [String] = []
        if published?.complete != true { warnings.append("TfL’s published calendar couldn’t be read. Check its strike updates for additional dates.") }
        if current?.isEmpty != false { warnings.append("Live and planned line reports are unavailable.") }
        let ids = Set((current ?? []).map(\.id)).sorted()
        if let onLive, !ids.isEmpty {
            var initial = board(current: current ?? [], forecast: [], calendar: published?.events ?? [], now: now, warnings: warnings)
            initial.checkingForecast = true
            await onLive(initial)
        }
        let utcDay = Date.ISO8601FormatStyle().year().month().day()
        let span = "/Status/" + now.formatted(utcDay) + "/to/" + now.addingTimeInterval(180 * 86_400).formatted(utcDay)
        let batches = stride(from: 0, to: ids.count, by: 20).map { Array(ids[$0..<min($0 + 20, ids.count)]) }
        var future: [Line] = []
        var incomplete = false
        for offset in stride(from: 0, to: batches.count, by: 4) {
            try Task.checkCancellation()
            let batches = batches[offset..<min(offset + 4, batches.count)]
            await withTaskGroup(of: ([String], [Line]?).self) { group in
                for ids in batches {
                    let urlRequest = request(ids.joined(separator: ",") + span)
                    group.addTask { (ids, try? await read(urlRequest)) }
                }
                for await (expected, result) in group {
                    if !Set(expected).isSubset(of: Set((result ?? []).map(\.id))) { incomplete = true }
                    future.append(contentsOf: result ?? [])
                }
            }
        }
        try Task.checkCancellation()
        if incomplete { warnings.append("Some services’ planned notices couldn’t be checked. The list may be incomplete.") }
        return board(current: current ?? [], forecast: future, calendar: published?.events ?? [], now: now, warnings: warnings)
    }
}
