//
//  ChatTokenParser.swift
//  PodcastAIKnowledge
//
//  Vorschläge für Tokens, während jemand tippt: „Podcast: Lage“ findet den
//  Podcast, „#daten“ das Tag, „Folge: Wahl“ eine Folge, „seit 1. Juni“ und
//  „letzte Woche“ einen Zeitraum.
//
//  Der Parser macht nur Vorschläge. Aus Text wird erst ein Token, wenn
//  jemand den Vorschlag antippt; eine gesendete Frage bleibt, wie sie ist.
//  Kein Modell ist beteiligt: Namen kommen aus der Mediathek, Tage aus dem
//  Kalender des Geräts.
//
//  Regeln für Tage ohne Jahr: gemeint ist das letzte Mal, dass dieser Tag
//  war, heute eingeschlossen. Am 26. September 2026 heißt „seit 1. Juni“
//  also 1. Juni 2026 und „seit 1. Dezember“ 1. Dezember 2025. Für „bis“
//  gilt dieselbe Regel. „seit Juni“ beginnt am 1. Juni, „bis Juni“ schließt
//  den ganzen Juni ein.
//

import Foundation
import PodcastAICore

/// Was sich als Token vorschlagen lässt: Podcasts, Tags und Folgen mit Namen.
public struct ChatTokenCatalog: Sendable {

    public struct Entry: Sendable, Hashable {
        public let token: ChatToken
        public let name: String
        /// Weitere Schreibweisen, etwa eines Tags.
        public let aliases: [String]

        public init(token: ChatToken, name: String, aliases: [String] = []) {
            self.token = token; self.name = name; self.aliases = aliases
        }
    }

    public var sources: [Entry]
    public var tags: [Entry]
    public var episodes: [Entry]

    public init(sources: [Entry] = [], tags: [Entry] = [], episodes: [Entry] = []) {
        self.sources = sources; self.tags = tags; self.episodes = episodes
    }
}

/// Ein Vorschlag über dem Eingabefeld.
public struct ChatTokenSuggestion: Sendable, Hashable, Identifiable {
    public let token: ChatToken
    /// Name von Podcast, Tag oder Folge. Bei Zeit-Tokens `nil`.
    public let name: String?
    /// Der Text im Feld, wenn der Vorschlag angenommen ist: ohne das Stück,
    /// aus dem er entstanden ist.
    public let remainingText: String

    public var id: String { token.id }

    public init(token: ChatToken, name: String?, remainingText: String) {
        self.token = token; self.name = name; self.remainingText = remainingText
    }
}

public struct ChatTokenParser: Sendable {

    public let now: Date
    public let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// Eine Zeitangabe im Text und das Stück, das sie belegt.
    public struct DateMatch: Sendable {
        public let token: ChatToken
        public let range: Range<String.Index>
    }

    // MARK: - Vorschläge

    /// Vorschläge zum Text im Feld. Zuerst, was jemand ausdrücklich
    /// eingeleitet hat („Podcast:“, „Tag:“, „#“, „Folge:“), dann Zeitangaben,
    /// dann Namen am Ende des Texts. Was `filter` schon enthält, fehlt.
    public func suggestions(
        for text: String, catalog: ChatTokenCatalog,
        excluding filter: LibraryFilter = LibraryFilter(), limit: Int = 6
    ) -> [ChatTokenSuggestion] {
        var result: [ChatTokenSuggestion] = []
        var seen: Set<String> = []
        func add(_ suggestion: ChatTokenSuggestion) {
            guard !filter.contains(suggestion.token), seen.insert(suggestion.id).inserted else { return }
            result.append(suggestion)
        }

        let prefixed = prefixedSuggestions(in: text, catalog: catalog)
        prefixed?.forEach(add)
        for match in dateMatches(in: text) {
            add(ChatTokenSuggestion(token: match.token, name: nil,
                                    remainingText: Self.removing(match.range, from: text)))
        }
        if prefixed == nil {
            trailingNameSuggestions(in: text, catalog: catalog).forEach(add)
        }
        return Array(result.prefix(limit))
    }

    /// „Podcast: …“, „Tag: …“, „#…“ oder „Folge: …“ am Ende des Texts. `nil`,
    /// wenn nichts davon dasteht. Ohne Suchwort kommen alle Einträge der Art.
    func prefixedSuggestions(in text: String, catalog: ChatTokenCatalog) -> [ChatTokenSuggestion]? {
        guard let prefix = Self.lastPrefix(in: text) else { return nil }
        let query = Self.fold(String(text[prefix.queryStart...]).trimmingCharacters(in: .whitespacesAndNewlines))
        let entries: [ChatTokenCatalog.Entry] = switch prefix.kind {
        case .source: catalog.sources
        case .tag: catalog.tags
        case .episode: catalog.episodes
        case .date: []
        }
        let remaining = Self.removing(prefix.start..<text.endIndex, from: text)
        return Self.ranked(entries, query: query).map {
            ChatTokenSuggestion(token: $0.token, name: $0.name, remainingText: remaining)
        }
    }

    /// Ein Name am Ende des Texts, ohne Einleitung: „Was sagt Lage“ schlägt
    /// „Lage der Nation“ vor. Nur Podcasts und Tags, deren Name mit den
    /// letzten ein bis vier Wörtern beginnt, und mindestens drei Buchstaben.
    /// Endet der Text mit Leerzeichen oder Satzzeichen, tippt niemand mehr
    /// an einem Namen.
    func trailingNameSuggestions(in text: String, catalog: ChatTokenCatalog) -> [ChatTokenSuggestion] {
        guard let last = text.last, last.isLetter || last.isNumber else { return [] }
        let words = Self.words(in: text)
        guard !words.isEmpty else { return [] }
        for count in stride(from: min(4, words.count), through: 1, by: -1) {
            let range = words[words.count - count].range.lowerBound..<words[words.count - 1].range.upperBound
            let fragment = Self.fold(String(text[range]))
            guard fragment.filter(\.isLetter).count >= 3 else { continue }
            let matches = (catalog.sources + catalog.tags).filter { entry in
                ([entry.name] + entry.aliases).contains { Self.fold($0).hasPrefix(fragment) }
            }
            guard !matches.isEmpty else { continue }
            let remaining = Self.removing(range, from: text)
            return matches.map { ChatTokenSuggestion(token: $0.token, name: $0.name, remainingText: remaining) }
        }
        return []
    }

    // MARK: - Zeitangaben

    /// Die erste Zeitangabe im Text, für Tests und einfache Aufrufer.
    public func dateToken(in text: String) -> ChatToken? {
        dateMatches(in: text).first?.token
    }

    /// Alle Zeitangaben im Text, in der Reihenfolge, in der sie dastehen.
    public func dateMatches(in text: String) -> [DateMatch] {
        let words = Self.words(in: text)
        var matches: [DateMatch] = []
        var index = 0
        while index < words.count {
            if let match = relativeMatch(at: index, in: words) ?? boundMatch(at: index, in: words) {
                matches.append(DateMatch(token: match.token, range: match.range))
                index = match.next
            } else {
                index += 1
            }
        }
        return matches
    }

    private struct Found {
        let token: ChatToken
        let range: Range<String.Index>
        /// Das erste Wort danach.
        let next: Int
    }

    /// „letzte Woche“, „in den letzten 30 Tagen“, „last month“.
    private func relativeMatch(at index: Int, in words: [Word]) -> Found? {
        guard Self.lastWords.contains(words[index].key), index + 1 < words.count else { return nil }
        var period: LibraryFilter.Period?
        var end = index + 1
        switch words[index + 1].key {
        case "woche", "week": period = .lastWeek
        case "monat", "month": period = .lastMonth
        case "7", "sieben", "seven", "30", "dreissig", "thirty":
            if index + 2 < words.count, Self.dayWords.contains(words[index + 2].key) {
                period = ["7", "sieben", "seven"].contains(words[index + 1].key) ? .lastWeek : .lastMonth
                end = index + 2
            }
        default: break
        }
        guard let period else { return nil }
        // Davor dürfen „in der“, „im“, „seit“ und Ähnliches stehen. Sie gehen
        // mit weg, sonst bliebe „Was wurde in der gesagt?“ stehen.
        var first = index
        if first > 0, Self.articleWords.contains(words[first - 1].key) { first -= 1 }
        if first > 0, Self.leadWords.contains(words[first - 1].key) { first -= 1 }
        return Found(token: .period(period),
                     range: words[first].range.lowerBound..<words[end].range.upperBound, next: end + 1)
    }

    /// „seit 1. Juni“, „bis 30.6.“, „ab Juni 2026“, „since June 1st“.
    private func boundMatch(at index: Int, in words: [Word]) -> Found? {
        let key = words[index].key
        let bound: Bound
        if Self.sinceWords.contains(key) {
            bound = .since
        } else if Self.untilWords.contains(key) {
            bound = .until
        } else {
            return nil
        }
        var cursor = index + 1
        if cursor < words.count, Self.fillerWords.contains(words[cursor].key) { cursor += 1 }
        guard cursor < words.count, let day = parseDay(at: cursor, in: words),
              let date = resolve(day: day.day, month: day.month, year: day.year, bound: bound)
        else { return nil }
        let last = day.next - 1
        return Found(token: bound == .since ? .since(date) : .before(date),
                     range: words[index].range.lowerBound..<words[last].range.upperBound, next: day.next)
    }

    private enum Bound { case since, until }

    private struct ParsedDay {
        let day: Int?
        let month: Int
        let year: Int?
        let next: Int
    }

    /// Ein Tag ab dem Wort `index`: „1. Juni 2026“, „1.6.“, „01.06.2026“,
    /// „2026-06-01“, „Juni“, „Juni 2026“, „June 1st, 2026“, „1 June“.
    private func parseDay(at index: Int, in words: [Word]) -> ParsedDay? {
        let key = words[index].key
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        // 2026-06-01
        let iso = key.split(separator: "-").map(String.init)
        if iso.count == 3, iso[0].count == 4, let year = Int(iso[0]), let month = Int(iso[1]), let day = Int(iso[2]) {
            return ParsedDay(day: day, month: month, year: year, next: index + 1)
        }
        // 1.6. oder 1.6 oder 01.06.2026 oder 1.6.26
        if parts.count >= 2, parts.count <= 3 || (parts.count == 4 && parts[3].isEmpty),
           let day = Int(parts[0]), let month = Int(parts[1]), !parts[1].isEmpty {
            let yearText = parts.count >= 3 ? parts[2] : ""
            if yearText.isEmpty {
                return ParsedDay(day: day, month: month, year: nil, next: index + 1)
            }
            if let year = Int(yearText), yearText.count == 2 || yearText.count == 4 {
                return ParsedDay(day: day, month: month, year: year, next: index + 1)
            }
            return nil
        }
        // 1. Juni, 1 June, 1st June
        if let day = Self.dayNumber(key), index + 1 < words.count, let month = Self.months[words[index + 1].key] {
            let year = index + 2 < words.count ? Self.yearNumber(words[index + 2].key) : nil
            return ParsedDay(day: day, month: month, year: year, next: index + (year == nil ? 2 : 3))
        }
        // Juni, Juni 2026, June 1, June 1st 2026
        if let month = Self.months[key] {
            if index + 1 < words.count, let day = Self.dayNumber(words[index + 1].key) {
                let year = index + 2 < words.count ? Self.yearNumber(words[index + 2].key) : nil
                return ParsedDay(day: day, month: month, year: year, next: index + (year == nil ? 2 : 3))
            }
            if index + 1 < words.count, let year = Self.yearNumber(words[index + 1].key) {
                return ParsedDay(day: nil, month: month, year: year, next: index + 2)
            }
            return ParsedDay(day: nil, month: month, year: nil, next: index + 1)
        }
        return nil
    }

    /// Macht aus Tag, Monat und Jahr den Beginn des Tages, ab dem gezählt
    /// wird („seit“), oder den Beginn des ersten Tages, der nicht mehr zählt
    /// („bis“). Ungültige Tage wie der 31. Juni ergeben nichts.
    private func resolve(day: Int?, month: Int, year: Int?, bound: Bound) -> Date? {
        guard (1...12).contains(month), day.map({ (1...31).contains($0) }) ?? true else { return nil }
        let today = calendar.startOfDay(for: now)
        func first(of year: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: day ?? 1)
            guard let date = calendar.date(from: components) else { return nil }
            let check = calendar.dateComponents([.year, .month, .day], from: date)
            guard check.year == year, check.month == month, check.day == (day ?? 1) else { return nil }
            return date
        }
        let date: Date
        if let year {
            guard let found = first(of: year < 100 ? 2000 + year : year) else { return nil }
            date = found
        } else {
            // Das letzte Mal, dass es diesen Tag gab, heute eingeschlossen.
            // Den 29. Februar gibt es nicht in jedem Jahr.
            let current = calendar.component(.year, from: now)
            guard let found = (0...8).lazy.compactMap({ first(of: current - $0) }).first(where: { $0 <= today })
            else { return nil }
            date = found
        }
        switch bound {
        case .since: return calendar.startOfDay(for: date)
        case .until: return calendar.date(byAdding: day == nil ? .month : .day, value: 1, to: date)
        }
    }

    // MARK: - Wörter

    struct Word {
        /// Das Wort ohne Satzzeichen am Ende, etwa „Juni“ in „Juni?“.
        let range: Range<String.Index>
        /// Kleingeschrieben, ohne Akzente, zum Vergleichen.
        let key: String
    }

    /// Wörter mit ihrer Stelle im Text. Satzzeichen am Rand gehören nicht
    /// dazu, ein Punkt nur, wenn das Wort eine Zahl ist wie „1.“ oder „1.6.“.
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lower = index
            var upper = end
            while lower < upper, leadingMarks.contains(text[lower]) { lower = text.index(after: lower) }
            while lower < upper, trailingMarks.contains(text[text.index(before: upper)]) {
                upper = text.index(before: upper)
            }
            if lower < upper, text[lower..<upper].contains(where: \.isLetter) {
                // „Juni.“ am Satzende: der Punkt gehört nicht zum Monat. „1st“ bleibt.
                while lower < upper, text[text.index(before: upper)] == "." { upper = text.index(before: upper) }
            }
            if lower < upper {
                words.append(Word(range: lower..<upper, key: fold(String(text[lower..<upper]))))
            }
            index = end
        }
        return words
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    private static let leadingMarks: Set<Character> = ["(", "[", "\"", "'", "„", "“", "‚", "»", "«"]
    private static let trailingMarks: Set<Character> = [
        ",", ";", ":", "!", "?", ")", "]", "\"", "'", "“", "”", "‘", "’", "»", "«", "…",
    ]

    private static func dayNumber(_ key: String) -> Int? {
        var text = key
        if text.hasSuffix(".") { text.removeLast() }
        for suffix in ["st", "nd", "rd", "th"] where text.hasSuffix(suffix) { text.removeLast(2) }
        guard (1...2).contains(text.count), let day = Int(text), (1...31).contains(day) else { return nil }
        return day
    }

    private static func yearNumber(_ key: String) -> Int? {
        var text = key
        if text.hasSuffix(".") { text.removeLast() }
        guard text.count == 4, let year = Int(text), (1900...2999).contains(year) else { return nil }
        return year
    }

    /// Monatsnamen auf Deutsch und Englisch, ausgeschrieben und kurz, ohne
    /// Akzente wie in ``fold(_:)``.
    static let months: [String: Int] = [
        "januar": 1, "jan": 1, "janner": 1, "january": 1,
        "februar": 2, "feb": 2, "february": 2,
        "marz": 3, "maerz": 3, "mar": 3, "mrz": 3, "march": 3,
        "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juni": 6, "jun": 6, "june": 6,
        "juli": 7, "jul": 7, "july": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "oktober": 10, "okt": 10, "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "dez": 12, "december": 12, "dec": 12,
    ]

    private static let sinceWords: Set<String> = ["seit", "ab", "vom", "von", "since", "from"]
    private static let untilWords: Set<String> = ["bis", "until", "till"]
    private static let fillerWords: Set<String> = ["dem", "den", "zum", "am", "the"]
    private static let lastWords: Set<String> = [
        "letzte", "letzten", "letzter", "vergangene", "vergangenen", "vergangener", "last", "past",
    ]
    private static let dayWords: Set<String> = ["tage", "tagen", "days"]
    private static let articleWords: Set<String> = ["der", "den", "the"]
    private static let leadWords: Set<String> = [
        "in", "im", "seit", "innerhalb", "since", "over", "during", "within",
    ]

    // MARK: - Einleitungen und Namen

    private struct Prefix {
        let kind: ChatToken.Kind
        /// Wo die Einleitung beginnt, also „P“ in „Podcast:“ oder „#“.
        let start: String.Index
        /// Wo das Suchwort beginnt.
        let queryStart: String.Index
    }

    /// Die letzte Einleitung im Text. Sie steht am Anfang oder nach einem
    /// Leerzeichen, alles danach ist das Suchwort.
    private static func lastPrefix(in text: String) -> Prefix? {
        var found: Prefix?
        var index = text.startIndex
        while index < text.endIndex {
            let atWordStart = index == text.startIndex || text[text.index(before: index)].isWhitespace
            if atWordStart {
                if text[index] == "#" {
                    found = Prefix(kind: .tag, start: index, queryStart: text.index(after: index))
                } else if let (kind, queryStart) = labeledPrefix(in: text, at: index) {
                    found = Prefix(kind: kind, start: index, queryStart: queryStart)
                }
            }
            index = text.index(after: index)
        }
        return found
    }

    /// „Podcast:“, „Tag:“, „Folge:“ oder „Episode:“ ab `index`, auch mit
    /// Leerzeichen vor dem Doppelpunkt.
    private static func labeledPrefix(in text: String, at index: String.Index) -> (ChatToken.Kind, String.Index)? {
        var end = index
        while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
        guard end > index else { return nil }
        let kind: ChatToken.Kind
        switch fold(String(text[index..<end])) {
        case "podcast": kind = .source
        case "tag": kind = .tag
        case "folge", "episode": kind = .episode
        default: return nil
        }
        var colon = end
        while colon < text.endIndex, text[colon] == " " { colon = text.index(after: colon) }
        guard colon < text.endIndex, text[colon] == ":" else { return nil }
        return (kind, text.index(after: colon))
    }

    /// Einträge, die zum Suchwort passen: Name beginnt damit, dann ein Wort
    /// im Namen, dann irgendwo im Namen. Sonst die Reihenfolge des Katalogs.
    static func ranked(_ entries: [ChatTokenCatalog.Entry], query: String) -> [ChatTokenCatalog.Entry] {
        guard !query.isEmpty else { return entries }
        func score(_ name: String) -> Int {
            let folded = fold(name)
            if folded.hasPrefix(query) { return 3 }
            if folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) {
                return 2
            }
            return folded.contains(query) ? 1 : 0
        }
        var scored: [(offset: Int, entry: ChatTokenCatalog.Entry, score: Int)] = []
        for (offset, entry) in entries.enumerated() {
            let best = ([entry.name] + entry.aliases).map(score).max() ?? 0
            if best > 0 { scored.append((offset, entry, best)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return scored.map(\.entry)
    }

    /// Der Text ohne `range`: doppelte Leerzeichen fallen weg, vor
    /// Satzzeichen steht keines mehr, außen auch nicht.
    static func removing(_ range: Range<String.Index>, from text: String) -> String {
        var result = text
        result.removeSubrange(range)
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]+([?!.,;:])", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
