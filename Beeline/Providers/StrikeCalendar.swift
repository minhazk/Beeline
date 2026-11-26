import Foundation

/// The public travel bulletin can announce dates before they reach the line-status API.
/// Read its dated lists only. Other lists include travel advice and service recovery times.
enum StrikeCalendar {
    struct Reading { var events: [LondonStrike]; var complete: Bool }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (1..<match.numberOfRanges).map { i in
                match.range(at: i).location == NSNotFound ? "" : source.substring(with: match.range(at: i))
            }
        }
    }

    private static let withdrawal = #"\b(?:strikes?|industrial action)\b(?:\s+(?:on|planned for|scheduled for)\s+((?:(?!\b(?:services?|trains?|buses|may|could)\b)[^.;!?]){1,90}?))?\s+(?:(?:have|has|had)\s+been\s+|(?:is|are|was|were)\s+)?(?:called off|cancelled|postponed|suspended)\b"#

    private static func withdrawn(_ qualifier: String, on start: Date) -> Bool {
        if qualifier.isEmpty { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = Time.london
        let month = calendar.monthSymbols[calendar.component(.month, from: start) - 1].lowercased()
        let pattern = #"((?:\d{1,2}(?:st|nd|rd|th)?(?:,\s*| and | & ))*\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)(?:\s+(\d{4}))?"#
        return captures(pattern, in: qualifier.lowercased()).contains { parts in
            parts[1] == month && (parts[2].isEmpty || Int(parts[2]) == calendar.component(.year, from: start))
                && parts[0].split(whereSeparator: { !$0.isNumber }).contains { Int($0) == calendar.component(.day, from: start) }
        }
    }

    static func parse(_ html: String) -> Reading? {
        // TfL's server currently delivers its rich text in Next's JSON string chunks. Decode
        // the strings as data. Older, server-rendered paragraphs can be read directly.
        let chunks: [String] = captures(#"<script[^>]*>\s*self\.__next_f\.push\((\[1,.*?\])\)\s*;?\s*</script>"#, in: html).compactMap {
            let value = try? JSONSerialization.jsonObject(with: Data($0[0].utf8)) as? [Any]
            return value?.last as? String
        }
        let article = captures(#"<main\b[^>]*>(.*?)</main>"#, in: html).first?.first ?? html
        let content = article + "\n" + chunks.joined()
        let blocks = captures(#"<(h[234]|li|p|div\s+data-fs-style=["']format\.h[234]["'])(?:\s+[^>]*)?>(.*?)</(?:h[234]|li|p|div)>"#, in:
            // The CMS sometimes wraps an entire list in a paragraph.
            content.replacingOccurrences(of: #"<p\s*>\s*(?=<[uo]l\b)"#, with: "", options: .regularExpression))
        var subject: String?
        var dates = false
        var sawDates = false
        var clear = false
        var missed = false
        var events: [LondonStrike] = []
        var withdrawals: [String: [String]] = [:]
        for block in blocks {
            let tag = block[0].lowercased()
            let words = block[1].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&#39;", with: "’").replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if tag == "p" {
                if words.range(of: #"\b(no (?:planned |upcoming |current |further )*strikes?|no strikes? (?:are )?(?:planned|announced))\b"#,
                               options: [.regularExpression, .caseInsensitive]) != nil { clear = true }
                if let subject, let qualifier = captures(withdrawal, in: words).first?.first {
                    withdrawals[subject, default: []].append(qualifier)
                    if qualifier.isEmpty { clear = true }
                }
            } else if tag == "h2" || tag.contains("format.h2") {
                dates = words.caseInsensitiveCompare("Strike dates") == .orderedSame
                if dates { sawDates = true }
                else if LondonStrikes.isAction(words) { subject = words }
                else { subject = nil }
            } else if dates && tag == "li" {
                guard let subject, let period = window(words) else { missed = true; continue }
                let title = subject.replacingOccurrences(of: #"\bstrikes$"#, with: "strike", options: [.regularExpression, .caseInsensitive])
                events.append(LondonStrike(id: "bulletin/\(subject)/\(period.lowerBound.timeIntervalSince1970)",
                                           title: title, mode: LondonStrikes.publishedMode(subject),
                                           start: period.lowerBound, end: period.upperBound, publishedDate: true))
            }
        }
        guard sawDates || clear else { return nil }
        let complete = !missed && (!events.isEmpty || clear)
        events.removeAll { event in
            guard let start = event.start else { return false }
            return withdrawals.contains { subject, qualifiers in
                event.id.hasPrefix("bulletin/\(subject)/") && qualifiers.contains { withdrawn($0, on: start) }
            }
        }
        return Reading(events: events, complete: complete)
    }

    /// TfL prints London wall time, often writing the shared month and year only at the end.
    static func window(_ text: String) -> ClosedRange<Date>? {
        let clockDay = #"(\d{1,2}):(\d{2})\s+(?:[a-z]+\s+)?(\d{1,2})(?:st|nd|rd|th)?"#
        let pattern = "^" + clockDay + #"(?:\s+([a-z]+))?(?:\s+(\d{4}))?\s+(?:to|until|–|-)\s+"# +
            clockDay + #"\s+([a-z]+)\s+(\d{4})[.]?$"#
        guard let parts = captures(pattern, in: text).first else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = Time.london
        func date(hour: String, minute: String, day: String, month: String, year: Int) -> Date? {
            guard let h = Int(hour), let m = Int(minute), let d = Int(day), (0...23).contains(h), (0...59).contains(m),
                  let i = calendar.monthSymbols.firstIndex(where: { $0.caseInsensitiveCompare(month) == .orderedSame }),
                  let date = calendar.date(from: DateComponents(year: year, month: i + 1, day: d, hour: h, minute: m)),
                  calendar.component(.day, from: date) == d else { return nil }
            return date
        }
        guard let year = Int(parts[9]),
              let end = date(hour: parts[5], minute: parts[6], day: parts[7], month: parts[8], year: year),
              var start = date(hour: parts[0], minute: parts[1], day: parts[2], month: parts[3].isEmpty ? parts[8] : parts[3],
                               year: Int(parts[4]) ?? year) else { return nil }
        if start > end && !parts[3].isEmpty && parts[4].isEmpty, let prior = calendar.date(byAdding: .year, value: -1, to: start) { start = prior }
        return start <= end ? start...end : nil
    }
}
