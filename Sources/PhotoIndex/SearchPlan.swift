import Foundation

public struct DateRange: Equatable, Sendable {
    /// Inclusive.
    public var start: Date
    /// Exclusive.
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// A parsed toolbar query. Tokens are AND-ed. A date narrows mixed queries and,
/// on its own, also matches file names that contain the same words.
public struct SearchPlan: Equatable, Sendable {
    public var raw: String
    public var tokens: [String]
    public var dateTokens: [String]
    public var dateRange: DateRange?
    public var matchesNothing: Bool

    public init(
        raw: String,
        tokens: [String],
        dateTokens: [String],
        dateRange: DateRange?,
        matchesNothing: Bool
    ) {
        self.raw = raw
        self.tokens = tokens
        self.dateTokens = dateTokens
        self.dateRange = dateRange
        self.matchesNothing = matchesNothing
    }

    public static let inactive = SearchPlan(
        raw: "",
        tokens: [],
        dateTokens: [],
        dateRange: nil,
        matchesNothing: false
    )

    public var isActive: Bool {
        matchesNothing || dateRange != nil || !tokens.isEmpty || !dateTokens.isEmpty
    }

    /// Words to draw boxes for. Date words are included so a year typed in a picture still highlights.
    public var highlightTokens: [String] {
        var seen = Set<String>()
        return (tokens + dateTokens).filter { seen.insert($0).inserted }
    }

    public var ftsExpression: String? {
        FTSQuery.expression(matching: tokens)
    }

    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> SearchPlan {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = SearchFold.string(trimmed)
        let pieces = SearchFold.tokens(in: folded)
        if pieces.isEmpty {
            return SearchPlan(raw: trimmed, tokens: [], dateTokens: [], dateRange: nil, matchesNothing: false)
        }

        var used = Array(repeating: false, count: pieces.count)
        var ranges: [DateRange] = []
        var dateWords: [String] = []
        var index = 0
        while index < pieces.count {
            if !used[index], pieces[index] == "today" {
                ranges.append(SearchDates.day(containing: now, calendar: calendar))
                used[index] = true
                index += 1
                continue
            }
            if !used[index], pieces[index] == "yesterday" {
                let previous = calendar.date(byAdding: .day, value: -1, to: now) ?? now
                ranges.append(SearchDates.day(containing: previous, calendar: calendar))
                used[index] = true
                index += 1
                continue
            }
            if let match = SearchDates.longestMatch(in: pieces, from: index, used: used, calendar: calendar) {
                ranges.append(match.range)
                for item in match.indexes {
                    used[item] = true
                    dateWords.append(pieces[item])
                }
                index = (match.indexes.max() ?? index) + 1
                continue
            }
            index += 1
        }

        let tokens = pieces.enumerated().compactMap { offset, piece in used[offset] ? nil : piece }
        let combined = SearchDates.intersect(ranges)
        return SearchPlan(
            raw: trimmed,
            tokens: tokens,
            dateTokens: dateWords,
            dateRange: combined.range,
            matchesNothing: combined.impossible
        )
    }
}

public enum FTSQuery {
    /// Prefix query. Tokens are already folded; each one is quoted so words like "and" stay literals.
    public static func expression(matching tokens: [String]) -> String? {
        let safe = tokens.filter(isToken)
        guard !safe.isEmpty else { return nil }
        return safe.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    public static func column(_ name: String, token: String) -> String? {
        guard isToken(token), isColumn(name), let body = expression(matching: [token]) else { return nil }
        return "\(name) : \(body)"
    }

    private static func isToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    private static func isColumn(_ name: String) -> Bool {
        name.allSatisfy { $0.isLetter }
    }
}

public enum TextHighlight {
    public static func matches(text: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let haystack = SearchFold.string(text)
        return tokens.contains { haystack.contains($0) }
    }
}

enum SearchFold {
    static func string(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func tokens(in folded: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !trimmed.isEmpty {
                tokens.append(trimmed)
            }
            current = ""
        }
        for character in folded {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

enum SearchDates {
    struct Match {
        var indexes: [Int]
        var range: DateRange
    }

    static let monthNames: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4),
        ("may", 5), ("june", 6), ("july", 7), ("august", 8),
        ("september", 9), ("sept", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4),
        ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9),
        ("oct", 10), ("nov", 11), ("dec", 12)
    ]

    static func longestMatch(in pieces: [String], from index: Int, used: [Bool], calendar: Calendar) -> Match? {
        let patterns: [(Int) -> Match?] = [
            { yearMonthDay(pieces, $0, used, calendar) },
            { dayMonthYear(pieces, $0, used, calendar) },
            { monthDayYear(pieces, $0, used, calendar) },
            { monthYear(pieces, $0, used, calendar) },
            { yearMonth(pieces, $0, used, calendar) },
            { yearOnly(pieces, $0, used, calendar) }
        ]
        for pattern in patterns {
            if let match = pattern(index) {
                return match
            }
        }
        return nil
    }

    static func intersect(_ ranges: [DateRange]) -> (range: DateRange?, impossible: Bool) {
        guard let first = ranges.first else { return (nil, false) }
        var start = first.start
        var end = first.end
        for range in ranges.dropFirst() {
            start = max(start, range.start)
            end = min(end, range.end)
        }
        if start >= end {
            return (nil, true)
        }
        return (DateRange(start: start, end: end), false)
    }

    static func day(containing date: Date, calendar: Calendar) -> DateRange {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateRange(start: start, end: end)
    }

    private static func yearMonthDay(_ pieces: [String], _ index: Int, _ used: [Bool], _ calendar: Calendar) -> Match? {
        guard let year = year(pieces, index, used),
              let month = monthNumber(pieces, index + 1, used),
              let day = dayNumber(pieces, index + 2, used),
              let range = exactDay(year: year, month: month, day: day, calendar: calendar) else { return nil }
        return Match(indexes: [index, index + 1, index + 2], range: range)
    }

    private static func dayMonthYear(_ pieces: [String], _ index: Int, _ used: [Bool], _ calendar: Calendar) -> Match? {
        guard let day = dayNumber(pieces, index, used),
              let month = monthName(pieces, index + 1, used),
              let year = year(pieces, index + 2, used),
              let range = exactDay(year: year, month: month, day: day, calendar: calendar) else { return nil }
        return Match(indexes: [index, index + 1, index + 2], range: range)
    }

    private static func monthDayYear(_ pieces: [String], _ index: Int, _ used: [Bool], _ calendar: Calendar) -> Match? {
        guard let month = monthName(pieces, index, used),
              let day = dayNumber(pieces, index + 1, used),
              let year = year(pieces, index + 2, used),
              let range = exactDay(year: year, month: month, day: day, calendar: calendar) else { return nil }
        return Match(indexes: [index, index + 1, index + 2], range: range)
    }

    private static func monthYear(_ pieces: [String], _ index: Int, _ used: [Bool], _ calendar: Calendar) -> Match? {
        guard let month = monthName(pieces, index, used),
              let year = year(pieces, index + 1, used),
              let range = monthRange(year: year, month: month, calendar: calendar) else { return nil }
        return Match(indexes: [index, index + 1], range: range)
    }

    private static func yearMonth(_ pieces: [String], _ index: Int, _ used: [Bool], _ calendar: Calendar) -> Match? {
        guard let year = year(pieces, index, used),
              let month = monthName(pieces, index + 1, used),
              let range = monthRange(year: year, month: month, calendar: calendar) else { return nil }
        return Match(indexes: [index, index + 1], range: range)
    }

    private static func yearOnly(_ pieces: [String], _ index: Int, _ used: [Bool], _ calendar: Calendar) -> Match? {
        guard let year = year(pieces, index, used),
              let range = yearRange(year, calendar: calendar) else { return nil }
        return Match(indexes: [index], range: range)
    }

    private static func year(_ pieces: [String], _ index: Int, _ used: [Bool]) -> Int? {
        guard let piece = available(pieces, index, used), piece.count == 4, let value = Int(piece), (1900...2100).contains(value) else {
            return nil
        }
        return value
    }

    private static func monthNumber(_ pieces: [String], _ index: Int, _ used: [Bool]) -> Int? {
        guard let piece = available(pieces, index, used), piece.count <= 2, piece.allSatisfy(\.isNumber), let value = Int(piece), (1...12).contains(value) else {
            return nil
        }
        return value
    }

    private static func dayNumber(_ pieces: [String], _ index: Int, _ used: [Bool]) -> Int? {
        guard let piece = available(pieces, index, used), piece.count <= 2, piece.allSatisfy(\.isNumber), let value = Int(piece), (1...31).contains(value) else {
            return nil
        }
        return value
    }

    private static func monthName(_ pieces: [String], _ index: Int, _ used: [Bool]) -> Int? {
        guard let piece = available(pieces, index, used) else { return nil }
        return monthNames.first { $0.0 == piece }?.1
    }

    private static func available(_ pieces: [String], _ index: Int, _ used: [Bool]) -> String? {
        guard index >= 0, index < pieces.count, !used[index] else { return nil }
        return pieces[index]
    }

    private static func exactDay(year: Int, month: Int, day: Int, calendar: Calendar) -> DateRange? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return self.day(containing: date, calendar: calendar)
    }

    private static func monthRange(year: Int, month: Int, calendar: Calendar) -> DateRange? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateRange(start: start, end: end)
    }

    private static func yearRange(_ year: Int, calendar: Calendar) -> DateRange? {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
        return DateRange(start: start, end: end)
    }
}

enum SearchDocument {
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let shortMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func filename(path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func dateText(for date: Date?, calendar: Calendar) -> String {
        guard let date else { return "" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              (1...12).contains(month) else { return "" }
        let monthText = String(format: "%02d", month)
        let dayText = String(format: "%02d", day)
        return "\(year) \(monthText) \(dayText) \(months[month - 1]) \(shortMonths[month - 1]) \(year)-\(monthText) \(year)-\(monthText)-\(dayText)"
    }
}
