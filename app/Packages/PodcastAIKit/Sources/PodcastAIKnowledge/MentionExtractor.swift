//
//  MentionExtractor.swift
//  PodcastAIKnowledge
//
//  Findet Links, Termine, Adressen, Telefonnummern, E-Mail-Adressen und
//  Namen in Shownotes und Transkript. Ohne Sprachmodell, auf dem Gerät und
//  bei gleicher Eingabe mit gleichem Ergebnis:
//
//  - Links, Termine, Adressen und Telefonnummern erkennt `NSDataDetector`,
//    E-Mail-Adressen kommen dort als `mailto:`-Link.
//  - Gesprochene Webadressen („beispiel punkt de slash kontakt“) erkennt
//    eine eigene, vorsichtige Regel, nur im Transkript.
//  - Personen, Organisationen und Orte erkennt `NLTagger` mit `.nameType`.
//
//  Termine löst `NSDataDetector` gegen heute auf. Hier zählt aber der Tag,
//  an dem die Folge erschienen ist: „am 3. März“ in einer Folge vom Februar
//  meint diesen März, nicht den nach heute. Fehlt Jahr oder Tag, heißt der
//  Termin ungefähr (``Mention/isVague``).
//
//  Gegen Rauschen: bloßes „heute“ oder „am Montag“ zählt im Transkript
//  nicht, ebenso wenig „24/7“ oder Kapitelmarken wie „03:15“ in den
//  Shownotes. Telefonnummern im Transkript brauchen ein Wort wie „Telefon“
//  in der Nähe, Links auf die eigene Adresse des Podcasts zählen nur aus
//  den Shownotes. Ein einzelnes Wort ist eine Person nur, wenn es mehrfach
//  und nicht nur am Satzanfang fällt oder zu einem vollen Namen gehört.
//  Was in einer Adresse oder Telefonnummer steht, ist kein Name. Jede Art
//  hat eine Obergrenze.
//

import Foundation
import NaturalLanguage
import PodcastAICore

public struct MentionExtractor: Sendable {

    /// Steigt, wenn sich die Regeln ändern. Gespeicherte Ergebnisse älterer
    /// Regeln gelten dann nicht mehr.
    public static let version = 2

    public struct Input: Sendable {
        /// HTML oder Text.
        public var shownotes: String?
        public var segments: [TranscriptSegment]
        /// Sprache des Transkripts, etwa „de_DE“. Hilft der Namenserkennung.
        public var languageCode: String?
        public var publishedAt: Date?
        /// Feed und Webseite des Podcasts. Links dorthin zählen nur aus den Shownotes.
        public var ownHosts: [String]

        public init(shownotes: String? = nil, segments: [TranscriptSegment] = [],
                    languageCode: String? = nil, publishedAt: Date? = nil, ownHosts: [String] = []) {
            self.shownotes = shownotes; self.segments = segments; self.languageCode = languageCode
            self.publishedAt = publishedAt; self.ownHosts = ownHosts
        }
    }

    /// Höchstens so viele Werte je Art.
    public static let limits: [Mention.Kind: Int] = [
        .link: 30, .date: 20, .address: 10, .phone: 10, .email: 10,
        .person: 25, .organization: 25, .place: 25,
    ]

    /// Höchstens so viele Fundstellen je Wert.
    public static let occurrenceLimit = 20

    let calendar: Calendar
    /// Der Zeitpunkt, gegen den `NSDataDetector` relative Angaben auflöst.
    let now: Date

    public init(calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    public func mentions(in input: Input) -> [Mention] {
        var collector = Collector()
        let own = Set(input.ownHosts.map(Self.baseDomain).filter { !$0.isEmpty })
        var names: [NameHit] = []
        var documents: [Document] = []
        if let html = input.shownotes, let document = Document(shownotes: html) {
            documents.append(document)
        }
        if let document = Document(segments: input.segments) {
            documents.append(document)
        }
        for document in documents {
            let taken = scanDetected(document, published: input.publishedAt, ownDomains: own, into: &collector)
            if document.origin == .transcript {
                scanSpokenAddresses(document, ownDomains: own, into: &collector)
            }
            names += nameHits(in: document, languageCode: input.languageCode, excluding: taken)
        }
        resolveNames(names, into: &collector)
        return collector.finish()
    }

    // MARK: - Datenerkennung

    /// Sammelt, was `NSDataDetector` findet. Gibt die Stellen von Links,
    /// Adressen und Telefonnummern zurück: Was darin steht, etwa „CA“ in
    /// „Cupertino, CA 95014“, ist kein Name.
    private func scanDetected(_ document: Document, published: Date?, ownDomains: Set<String>,
                              into collector: inout Collector) -> [NSRange] {
        let types: NSTextCheckingResult.CheckingType = [.link, .date, .address, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let text = document.text as NSString
        let whole = NSRange(location: 0, length: text.length)
        var taken: [NSRange] = []
        for match in detector.matches(in: document.text, range: whole) {
            let matched = text.substring(with: match.range)
            let occurrence = document.occurrence(at: match.range)
            if match.resultType == .link || match.resultType == .address || match.resultType == .phoneNumber {
                taken.append(match.range)
            }
            switch match.resultType {
            case .link:
                guard let url = match.url else { continue }
                addLink(url, matched: matched, origin: document.origin, ownDomains: ownDomains,
                        occurrence: occurrence, into: &collector)
            case .date:
                // Der Text davor, nur aus derselben Zeile.
                let lead = max(0, match.range.location - 40)
                let before = text.substring(with: NSRange(location: lead, length: match.range.location - lead))
                    .components(separatedBy: .newlines).last ?? ""
                guard var detected = match.date else { continue }
                // „bis 12. November“ ist für die Erkennung ein Zeitraum ab
                // jetzt. Gemeint ist sein Ende, nicht der heutige Tag.
                if match.duration > 0, let first = Self.words(matched).first, Self.untilWords.contains(first) {
                    detected = detected.addingTimeInterval(match.duration)
                }
                guard let resolved = resolveDate(matched, detected: detected, published: published,
                                                 origin: document.origin, before: before) else { continue }
                collector.add(Mention(
                    kind: .date, normalized: dayKey(resolved.date), display: Self.clean(matched),
                    date: resolved.date, hasTime: resolved.hasTime, isVague: resolved.vague,
                    occurrences: [occurrence]))
            case .address:
                let display = Self.clean(matched.replacingOccurrences(of: "\n", with: ", "))
                guard display.count >= 8 else { continue }
                collector.add(Mention(
                    kind: .address, normalized: Self.addressKey(display), display: display,
                    url: Self.mapsURL(display), occurrences: [occurrence]))
            case .phoneNumber:
                let raw = match.phoneNumber ?? matched
                guard let number = Self.phoneKey(raw) else { continue }
                if document.origin == .transcript,
                   !Self.containsPhoneCue(document.window(around: match.range, radius: 70)) { continue }
                collector.add(Mention(
                    kind: .phone, normalized: number, display: Self.clean(matched),
                    url: URL(string: "tel:\(number)"), occurrences: [occurrence]))
            default:
                continue
            }
        }
        return taken
    }

    private func addLink(_ url: URL, matched: String, origin: Mention.Occurrence.Origin,
                         ownDomains: Set<String>, occurrence: Mention.Occurrence,
                         into collector: inout Collector) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "mailto" {
            let address = url.absoluteString.dropFirst("mailto:".count)
                .split(separator: "?").first.map(String.init)?.removingPercentEncoding ?? ""
            guard address.contains("@"), address.count <= 120 else { return }
            let key = address.lowercased()
            collector.add(Mention(kind: .email, normalized: key, display: address,
                                  url: URL(string: "mailto:\(key)"), occurrences: [occurrence]))
            return
        }
        guard scheme == "http" || scheme == "https",
              let link = Self.linkKey(url) else { return }
        if origin == .transcript, ownDomains.contains(Self.baseDomain(link.host)) { return }
        collector.add(Mention(kind: .link, normalized: link.key, display: link.display,
                              url: url, occurrences: [occurrence]))
    }

    // MARK: - Gesprochene Webadressen

    /// „beispiel punkt de“, „example dot com“, „www beispiel punkt de slash kontakt“.
    ///
    /// Vorsichtig, denn „Punkt“ ist auch ein gewöhnliches Wort: Die Endung
    /// muss aus einer festen Liste stammen, kein Teil darf ein Füllwort wie
    /// „der“ oder „the“ sein, und es braucht ein Zeichen, dass eine Adresse
    /// gemeint ist: „www“ davor, einen Pfad dahinter, ein Wort wie „Webseite“
    /// oder „Link“ kurz davor oder „unter“, „auf“, „bei“ direkt davor. So
    /// bleibt „Bei der Regulierung ist das ein wichtiger Punkt de facto
    /// entscheidend“ ein Satz: Das „bei“ steht weit vorn, direkt vor der
    /// vermeintlichen Adresse steht „ein“.
    static func spokenWebAddresses(in text: String) -> [(range: NSRange, host: String, path: String)] {
        guard let regex = spokenPattern else { return [] }
        let ns = text as NSString
        var found: [(range: NSRange, host: String, path: String)] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hasWWW = match.range(at: 1).location != NSNotFound
            let labelText = ns.substring(with: match.range(at: 2))
            let tld = ns.substring(with: match.range(at: 3)).lowercased()
            let pathText = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
            // Nur an Leerzeichen trennen: „mein-podcast“ ist ein Teil.
            var labels = spaced(labelText).filter { !separatorWords.contains($0) }
            if labels.first == "www" { labels.removeFirst() }
            guard !labels.isEmpty, labels.allSatisfy({ !spokenStopwords.contains($0) && !$0.allSatisfy(\.isNumber) })
            else { continue }
            let path = spaced(pathText).filter { !pathWords.contains($0) }
            guard path.allSatisfy({ !spokenStopwords.contains($0) }) else { continue }
            let lead = max(0, match.range.location - 80)
            let before = words(ns.substring(with: NSRange(location: lead, length: match.range.location - lead)))
            let cue = before.suffix(6).contains { spokenCues.contains($0) }
                || before.suffix(2).contains { nearSpokenCues.contains($0) }
                || before.last.map(adjacentSpokenCues.contains) == true
            guard hasWWW || !path.isEmpty || cue else { continue }
            let host = (labels + [tld]).joined(separator: ".")
            found.append((match.range, host, path.isEmpty ? "" : "/" + path.joined(separator: "/")))
        }
        return found
    }

    private func scanSpokenAddresses(_ document: Document, ownDomains: Set<String>,
                                     into collector: inout Collector) {
        for spoken in Self.spokenWebAddresses(in: document.text) {
            guard !ownDomains.contains(Self.baseDomain(spoken.host)),
                  let url = URL(string: "https://\(spoken.host)\(spoken.path)") else { continue }
            let display = spoken.host + spoken.path
            collector.add(Mention(kind: .link, normalized: display.lowercased(), display: display,
                                  url: url, occurrences: [document.occurrence(at: spoken.range)]))
        }
    }

    private static let spokenPattern = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}-])((?:www|w\s+w\s+w)\s+(?:(?:punkt|dot)\s+)?)?((?:[a-z0-9][a-z0-9-]{1,40}\s+(?:punkt|dot)\s+){1,3})"#
            + #"(de|com|org|net|at|ch|eu|io|info|fm|tv|ai|app|dev|me|co|uk|nl|fr|it|es|biz|online|shop|blog|news|podcast)"#
            + #"(?![\p{L}\p{N}])((?:\s+(?:slash|schrägstrich|schraegstrich)\s+[a-z0-9][a-z0-9-]{0,40}){0,3})"#,
        options: [.caseInsensitive])

    private static let separatorWords: Set<String> = ["punkt", "dot"]
    private static let pathWords: Set<String> = ["slash", "schrägstrich", "schraegstrich"]

    /// Wörter, die nie Teil einer gesprochenen Adresse sind.
    private static let spokenStopwords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "und", "oder", "aber", "ist", "sind", "war", "im", "in", "am", "an", "um", "zum", "zur", "vom",
        "beim", "mit", "auf", "für", "fuer", "von", "bei", "nach", "aus", "als", "wie", "so", "da", "es",
        "er", "sie", "wir", "ihr", "ich", "du", "man", "nicht", "noch", "auch", "nur", "schon", "dann",
        "the", "a", "an", "and", "or", "to", "of", "on", "at", "is", "it", "this", "that", "for",
        "with", "by", "from", "was", "are", "be", "as", "so", "no", "not",
    ]

    /// Wörter kurz vor einer Adresse, die sagen, dass eine gemeint ist.
    /// Sie zählen bis zu sechs Wörter davor.
    private static let spokenCues: Set<String> = [
        "website", "webseite", "websites", "webseiten", "internetseite", "homepage", "url", "domain",
        "link", "links", "shownotes", "visit", "besucht", "besuchen", "go", "head", "check",
    ]

    /// Zählen nur in den letzten zwei Wörtern: „findet ihr unter beispiel
    /// punkt de“, aber nicht „unter anderem ein wichtiger Punkt de facto“.
    private static let nearSpokenCues: Set<String> = [
        "unter", "seite", "site", "adresse", "online", "internet", "web", "findet", "findest", "finden",
        "find", "schaut", "schau", "geht", "gehe",
    ]

    /// Kleine Wörter, die nur direkt vor der Adresse zählen: „auf beispiel
    /// punkt de“. Weiter vorn stehen sie in fast jedem Satz.
    private static let adjacentSpokenCues: Set<String> = [
        "auf", "bei", "zu", "über", "ueber", "via", "at", "on", "to",
    ]

    // MARK: - Termine

    struct ResolvedDate {
        let date: Date
        let hasTime: Bool
        let vague: Bool
    }

    /// Löst einen erkannten Termin gegen das Erscheinungsdatum auf.
    /// `before` ist der Text kurz vor der Stelle, für „jeden Freitag“.
    func resolveDate(_ matched: String, detected: Date, published: Date?,
                     origin: Mention.Occurrence.Origin, before: String = "") -> ResolvedDate? {
        let lower = matched.lowercased()
        // „24/7“ heißt rund um die Uhr, nicht der 24. Juli.
        guard !Self.contains(lower, Self.aroundTheClockPattern) else { return nil }
        let tokens = Set(Self.words(lower))
        let hasTime = Self.contains(lower, Self.timePattern)
        // Ohne Uhrzeit, sonst hielte „18.30 Uhr“ sich für den 18. März.
        let withoutTime = Self.removing(Self.timePattern, from: lower)
        let hasYear = Self.contains(withoutTime, Self.yearPattern)
        let hasMonthName = !tokens.isDisjoint(with: Self.monthNames)
        // „3/5“ ohne Jahr ist im Gespräch eher ein Verhältnis als ein Datum.
        let hasSlashDate = Self.contains(withoutTime, Self.slashDatePattern)
            && (origin == .shownotes || hasYear)
        let hasNumericDate = Self.contains(withoutTime, Self.numericDatePattern) || hasSlashDate

        guard hasMonthName || hasNumericDate else {
            // Nur ein Jahr, eine Uhrzeit, ein Wochentag oder „morgen“. Im
            // Transkript ist das fast immer Gesprächsfluss, kein Termin.
            guard origin == .shownotes, !hasYear, let published else { return nil }
            // Eine bloße Uhrzeit wie „03:15 News“ ist eine Kapitelmarke.
            // Es braucht „heute“, „morgen“ oder einen Wochentag.
            guard !tokens.isDisjoint(with: Self.relativeWords.union(Self.weekdayNames)) else { return nil }
            // „Neue Folgen jeden Freitag“ ist ein Rhythmus, kein Termin.
            let lead = Set(Self.words(before).suffix(3))
            guard tokens.isDisjoint(with: Self.recurringWords), lead.isDisjoint(with: Self.recurringWords)
            else { return nil }
            return relativeDate(detected: detected, tokens: tokens, hasTime: hasTime, published: published)
        }

        // Gibt es einen Tag? Uhrzeit und Jahr zählen dafür nicht.
        let hasDay = Self.contains(Self.removing(Self.yearPattern, from: withoutTime), Self.dayPattern)

        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: detected)
        if !hasTime { parts.hour = 0; parts.minute = 0 }
        if !hasDay { parts.day = 1 }
        if !hasYear, let published {
            parts.year = nearestYear(for: parts, published: published)
        }
        guard let year = parts.year, (1900...2100).contains(year),
              let date = calendar.date(from: parts) else { return nil }
        return ResolvedDate(date: date, hasTime: hasTime, vague: !hasYear || !hasDay)
    }

    /// „morgen“, „heute Abend“, „am Dienstag um 20 Uhr“ aus Shownotes,
    /// gerechnet ab dem Tag, an dem die Folge erschien.
    private func relativeDate(detected: Date, tokens: Set<String>, hasTime: Bool, published: Date) -> ResolvedDate? {
        let day: Date
        let publishedDay = calendar.startOfDay(for: published)
        if tokens.isDisjoint(with: Self.relativeWords), !tokens.isDisjoint(with: Self.weekdayNames) {
            // Der nächste solche Wochentag nach dem Erscheinen.
            let weekday = calendar.component(.weekday, from: detected)
            var candidate = publishedDay
            for _ in 0..<7 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
                candidate = next
                if calendar.component(.weekday, from: candidate) == weekday { break }
            }
            day = candidate
        } else {
            let offset = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: detected)).day ?? 0
            guard abs(offset) <= 14,
                  let shifted = calendar.date(byAdding: .day, value: offset, to: publishedDay) else { return nil }
            day = shifted
        }
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        if hasTime {
            let time = calendar.dateComponents([.hour, .minute], from: detected)
            parts.hour = time.hour; parts.minute = time.minute
        }
        guard let date = calendar.date(from: parts) else { return nil }
        return ResolvedDate(date: date, hasTime: hasTime, vague: true)
    }

    /// Das Jahr, in dem ein Termin ohne Jahr am ehesten liegt: kommende
    /// Termine vor vergangenen, ein vergangener nur, wenn er deutlich näher ist.
    private func nearestYear(for parts: DateComponents, published: Date) -> Int? {
        let base = calendar.component(.year, from: published)
        let reference = calendar.startOfDay(for: published)
        var best: (year: Int, score: Double)?
        for year in [base - 1, base, base + 1] {
            var candidate = parts
            candidate.year = year
            guard let date = calendar.date(from: candidate) else { continue }
            let delta = date.timeIntervalSince(reference)
            let score = delta >= -86_400 ? delta : -delta * 3
            if best == nil || score < best!.score { best = (year, score) }
        }
        return best?.year
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let timePattern = try? NSRegularExpression(
        pattern: #"\b\d{1,2}(?:[:.]\d{2})?\s*(?:uhr|h\b|am\b|pm\b|a\.m\.|p\.m\.)|\b\d{1,2}:\d{2}\b"#,
        options: [.caseInsensitive])
    private static let yearPattern = try? NSRegularExpression(
        pattern: #"\b(?:19|20)\d{2}\b|(?<=\b\d{1,2}\.\d{1,2}\.)\d{2}\b|(?<=\b\d{1,2}-\d{1,2}-)\d{2}\b"#,
        options: [])
    /// „3.5.“, „2026-11-12“ und „12-11-2026“. Schrägstriche prüft ``slashDatePattern``.
    private static let numericDatePattern = try? NSRegularExpression(
        pattern: #"\b\d{1,2}\.\s?\d{1,2}\b|\b\d{4}-\d{1,2}-\d{1,2}\b|\b\d{1,2}-\d{1,2}-\d{2,4}\b"#,
        options: [])
    private static let slashDatePattern = try? NSRegularExpression(
        pattern: #"\b\d{1,2}/\d{1,2}\b"#, options: [])
    private static let aroundTheClockPattern = try? NSRegularExpression(
        pattern: #"\b24\s?/\s?7\b"#, options: [])
    /// Ein Tag, auch mit englischer Endung wie „12th“ oder „3rd“.
    private static let dayPattern = try? NSRegularExpression(
        pattern: #"\b(?:0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?\b"#, options: [])

    static let monthNames: Set<String> = [
        "januar", "jänner", "jaenner", "februar", "märz", "maerz", "april", "mai", "juni", "juli",
        "august", "september", "oktober", "november", "dezember",
        "jan", "feb", "mär", "mrz", "apr", "jun", "jul", "aug", "sep", "sept", "okt", "nov", "dez",
        "january", "february", "march", "may", "june", "july", "october", "december", "mar", "oct", "dec",
    ]

    static let weekdayNames: Set<String> = [
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonnabend", "sonntag",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    private static let relativeWords: Set<String> = [
        "heute", "morgen", "übermorgen", "uebermorgen", "gestern", "vorgestern", "heut",
        "today", "tomorrow", "yesterday", "tonight",
    ]

    /// Wörter, mit denen ein offener Zeitraum bis zu einem Tag beginnt.
    private static let untilWords: Set<String> = ["bis", "until", "till", "til", "through", "thru"]

    /// Wörter für einen Rhythmus: „jeden Freitag“, „every Friday“.
    private static let recurringWords: Set<String> = [
        "jeden", "jede", "jedem", "jeder", "alle", "immer", "wöchentlich", "woechentlich", "regelmäßig",
        "regelmaessig", "every", "each", "weekly",
    ]

    // MARK: - Namen

    struct NameHit {
        var kind: Mention.Kind
        let name: String
        let tokens: [String]
        let occurrence: Mention.Occurrence
        let sentenceInitial: Bool
        var key: String { Self.fold(name) }
        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
    }

    private func nameHits(in document: Document, languageCode: String?, excluding taken: [NSRange]) -> [NameHit] {
        let text = document.text
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        let whole = text.startIndex..<text.endIndex
        if let language = Self.language(languageCode, text: text) {
            tagger.setLanguage(language, range: whole)
        }
        var found: [(kind: Mention.Kind, range: Range<String.Index>)] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: whole, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, let kind = Self.kind(for: tag) { found.append((kind, range)) }
            return true
        }
        var hits: [NameHit] = []
        for (tagged, range) in found {
            var kind = tagged
            // „CA“ in „Cupertino, CA 95014“ gehört zur Adresse.
            let whole = NSRange(range, in: text)
            if taken.contains(where: { NSIntersectionRange($0, whole).length > 0 }) { continue }
            var parts = Self.tokenRanges(in: text, range: range)
            while let first = parts.first, Self.leadingNoise.contains(NameHit.fold(String(text[first]))) {
                parts.removeFirst()
            }
            guard let start = parts.first, parts.count <= 5 else { continue }
            let tokens = parts.map { String(text[$0]) }
            let name = tokens.joined(separator: " ")
            guard Self.isPlausibleName(name) else { continue }
            if tokens.count > 1, let lexical = tagger.tag(at: start.lowerBound, unit: .word, scheme: .lexicalClass).0 {
                // „Unser Gast“ ist niemand: Ein Name beginnt nicht mit einem Begleiter.
                if lexical == .determiner { continue }
                // „Deutsche Bahn“ ist keine Person: Ein Name beginnt nicht mit einem Adjektiv.
                if kind == .person, lexical == .adjective { kind = .organization }
            }
            // Satzanfang wie bisher ab dem ersten Wort, auch wenn es wegfiel:
            // „Die Studie“ am Satzanfang bleibt am Satzanfang.
            hits.append(NameHit(kind: kind, name: name, tokens: tokens,
                                occurrence: document.occurrence(at: whole),
                                sentenceInitial: document.isSentenceInitial(whole.location)))
        }
        return hits
    }

    /// Die Wörter in einem Bereich, an Leerraum getrennt.
    private static func tokenRanges(in text: String, range: Range<String.Index>) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < range.upperBound, !text[end].isWhitespace { end = text.index(after: end) }
            result.append(index..<end)
            index = end
        }
        return result
    }

    /// Führt Namen zusammen und siebt einzelne Wörter aus.
    ///
    /// Im Deutschen beginnt jedes Hauptwort groß, und die Namenserkennung
    /// hält manches davon für eine Person. Ein einzelnes Wort zählt deshalb
    /// als Person nur, wenn es zu einem vollen Namen der Folge gehört, dann
    /// kommt es zu diesem, oder wenn es mindestens zweimal und nicht nur am
    /// Satzanfang fällt. Einzelne Organisationen und Orte brauchen eine
    /// Stelle mitten im Satz oder zwei Nennungen.
    private func resolveNames(_ hits: [NameHit], into collector: inout Collector) {
        var fullNames: [String: String] = [:]
        var fullCounts: [String: Int] = [:]
        for hit in hits where hit.kind == .person && hit.tokens.count > 1 {
            fullCounts[hit.key, default: 0] += 1
        }
        for hit in hits where hit.kind == .person && hit.tokens.count > 1 {
            for part in [hit.tokens.first!, hit.tokens.last!] {
                let token = NameHit.fold(part)
                guard token.count >= 3 else { continue }
                if let existing = fullNames[token], (fullCounts[existing] ?? 0) >= (fullCounts[hit.key] ?? 0) { continue }
                fullNames[token] = hit.key
            }
        }
        let displayFor = Dictionary(hits.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })

        var singles: [String: [NameHit]] = [:]
        for hit in hits {
            if hit.tokens.count > 1 || Self.isAcronym(hit.name) {
                collector.add(Mention(kind: hit.kind, normalized: hit.key, display: hit.name,
                                      url: hit.kind == .place ? Self.mapsURL(hit.name) : nil,
                                      occurrences: [hit.occurrence]))
            } else if hit.kind == .person, let full = fullNames[hit.key], let display = displayFor[full] {
                collector.add(Mention(kind: .person, normalized: full, display: display,
                                      occurrences: [hit.occurrence]))
            } else {
                singles["\(hit.kind.rawValue)|\(hit.key)", default: []].append(hit)
            }
        }
        for group in singles.values {
            guard let first = group.first else { continue }
            let midSentence = group.contains { !$0.sentenceInitial }
            let accepted = first.kind == .person
                ? group.count >= 2 && midSentence
                : group.count >= 2 || midSentence
            guard accepted else { continue }
            for hit in group {
                collector.add(Mention(kind: hit.kind, normalized: hit.key, display: first.name,
                                      url: hit.kind == .place ? Self.mapsURL(first.name) : nil,
                                      occurrences: [hit.occurrence]))
            }
        }
    }

    private static func kind(for tag: NLTag) -> Mention.Kind? {
        switch tag {
        case .personalName: .person
        case .organizationName: .organization
        case .placeName: .place
        default: nil
        }
    }

    private static func language(_ code: String?, text: String) -> NLLanguage? {
        if let code, let prefix = code.split(whereSeparator: { $0 == "_" || $0 == "-" }).first, prefix.count == 2 {
            return NLLanguage(rawValue: String(prefix).lowercased())
        }
        return NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(2_000)))
    }

    /// Wörter, die vor einem Namen stehen, aber nicht zu ihm gehören.
    private static let leadingNoise: Set<String> = [
        "the", "der", "die", "das", "den", "dem", "des", "herr", "herrn", "frau", "dr.", "dr", "prof.",
        "prof", "mr.", "mr", "mrs.", "mrs", "ms.", "ms",
        "mein", "meine", "meinem", "meinen", "meiner", "unser", "unsere", "unserem", "unseren", "unserer",
        "euer", "eure", "eurem", "euren", "eurer", "my", "our", "your",
    ]

    /// Großgeschriebene Wörter, die die Namenserkennung gern für Namen hält.
    /// In gefalteter Form, „Gäste“ steht hier als „gaste“.
    private static let nameStopwords: Set<String> = [
        "heute", "morgen", "gestern", "hallo", "danke", "okay", "ok", "ja", "nein", "genau", "also",
        "ki", "ai", "folge", "podcast", "episode", "shownotes", "link", "links", "hi", "hey", "yes", "no",
        "thanks", "today", "tomorrow", "yesterday", "gast", "gaste", "guest", "guests",
    ]

    static func isPlausibleName(_ name: String) -> Bool {
        guard (2...60).contains(name.count),
              let first = name.first, first.isLetter, first.isUppercase,
              !name.contains(where: { $0.isNumber || "@/\\_:#".contains($0) }) else { return false }
        let key = NameHit.fold(name)
        if nameStopwords.contains(key) || monthNames.contains(key) || weekdayNames.contains(key) { return false }
        // „beispiel.de“ ist ein Link, kein Name.
        return name.range(of: #"[\p{L}\p{N}]\.\p{L}{2,}"#, options: .regularExpression) == nil
    }

    static func isAcronym(_ name: String) -> Bool {
        name.count >= 2 && name.count <= 6 && name.allSatisfy { $0.isUppercase || $0 == "&" }
    }

    // MARK: - Schlüssel

    /// Host ohne „www.“, Pfad ohne Schrägstrich am Ende und die Anfrage ohne
    /// Tracking. Was in der Anfrage bleibt, gehört dazu: „youtube.com/watch?v=…“
    /// ist je Video ein eigener Link. Sprungmarken zählen nicht. Mediendateien
    /// und Adressen ohne echte Endung auch nicht.
    static func linkKey(_ url: URL) -> (key: String, display: String, host: String)? {
        guard var host = url.host(percentEncoded: false)?.lowercased(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard let tld = host.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        let lowerPath = path.lowercased()
        if mediaExtensions.contains(where: { lowerPath.hasSuffix(".\($0)") }) { return nil }
        let query = (url.query(percentEncoded: true) ?? "")
            .split(separator: "&")
            .filter { item in
                let name = item.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                return !name.isEmpty && !name.hasPrefix("utm_") && !trackingParameters.contains(name)
            }
            .joined(separator: "&")
        let base = host + path
        guard !query.isEmpty else { return (base.lowercased(), base, host) }
        // Werte in der Anfrage unterscheiden Groß und Klein, etwa die Kennung eines Videos.
        return (base.lowercased() + "?" + query, base + "?" + (query.removingPercentEncoding ?? query), host)
    }

    /// Parameter, die nur sagen, woher jemand kam.
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid", "igshid", "igsh",
        "si", "ref", "ref_src", "ref_url", "_hsenc", "_hsmi", "mkt_tok", "feature", "trk", "spm",
    ]

    private static let mediaExtensions = [
        "mp3", "m4a", "aac", "ogg", "opus", "wav", "mp4", "m4v", "mov", "jpg", "jpeg", "png", "gif", "webp", "svg",
    ]

    /// Die Domain ohne Subdomain, etwa „example.org“ aus „feeds.example.org“.
    static func baseDomain(_ host: String) -> String {
        var host = host.lowercased()
        if let parsed = URL(string: host)?.host, host.contains("://") { host = parsed.lowercased() }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        let secondLevel = ["co", "com", "org", "net", "gov", "ac", "or"]
        if labels.count >= 3, labels.last!.count == 2, secondLevel.contains(labels[labels.count - 2]) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Nur Ziffern, ein führendes „+“ bleibt, „00“ wird zu „+“.
    static func phoneKey(_ raw: String) -> String? {
        var digits = raw.filter(\.isNumber)
        let international = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        if !international, digits.hasPrefix("00") { digits.removeFirst(2); digits = "+" + digits }
        else if international { digits = "+" + digits }
        let count = digits.filter(\.isNumber).count
        return (6...16).contains(count) ? digits : nil
    }

    private static func containsPhoneCue(_ text: String) -> Bool {
        let tokens = words(text.lowercased())
        return tokens.contains { token in phoneCues.contains { token.hasPrefix($0) } }
    }

    private static let phoneCues = [
        "telefon", "tel", "anruf", "anrufen", "ruf", "hotline", "nummer", "rufnummer", "handy", "whatsapp",
        "call", "phone", "dial", "number",
    ]

    static func addressKey(_ address: String) -> String {
        let folded = address.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "strasse", with: "str")
            .replacingOccurrences(of: "str.", with: "str")
        return words(folded).joined(separator: " ")
    }

    static func mapsURL(_ query: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    // MARK: - Hilfen

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-–"))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    private static func spaced(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func contains(_ text: String, _ regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func removing(_ regex: NSRegularExpression?, from text: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
    }
}

// MARK: - Sammeln

/// Führt gleiche Werte zusammen, merkt sich, was zuerst kam, und hält die Grenzen ein.
struct Collector {
    private var items: [String: Mention] = [:]
    private var firstSeen: [String: Int] = [:]
    private var counts: [String: Int] = [:]

    mutating func add(_ mention: Mention) {
        let id = mention.id
        counts[id, default: 0] += 1
        guard var existing = items[id] else {
            firstSeen[id] = firstSeen.count
            items[id] = mention
            return
        }
        // Ein Termin mit Uhrzeit ersetzt denselben Tag ohne; einer mit
        // Jahr und Tag macht ihn genau.
        if existing.kind == .date {
            if !existing.hasTime, mention.hasTime {
                existing.date = mention.date
                existing.hasTime = true
            }
            existing.isVague = existing.isVague && mention.isVague
        }
        for occurrence in mention.occurrences where existing.occurrences.count < MentionExtractor.occurrenceLimit {
            let duplicate = existing.occurrences.contains {
                $0.origin == occurrence.origin && $0.time == occurrence.time
                    && ($0.time != nil || $0.context == occurrence.context)
            }
            if !duplicate { existing.occurrences.append(occurrence) }
        }
        items[id] = existing
    }

    func finish() -> [Mention] {
        var result: [Mention] = []
        for kind in Mention.Kind.allCases {
            let order = { (id: String) in firstSeen[id] ?? .max }
            var list = items.values.filter { $0.kind == kind }
            if kind.isName {
                list.sort { (counts[$0.id] ?? 0, -order($0.id)) > (counts[$1.id] ?? 0, -order($1.id)) }
            } else {
                list.sort { order($0.id) < order($1.id) }
            }
            list = Array(list.prefix(MentionExtractor.limits[kind] ?? 20))
            if kind == .date {
                list.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            }
            result += list.map { mention in
                var sorted = mention
                sorted.occurrences = Self.ordered(mention.occurrences)
                return sorted
            }
        }
        return result
    }

    /// Shownotes zuerst, dann das Transkript in der Zeitfolge.
    private static func ordered(_ occurrences: [Mention.Occurrence]) -> [Mention.Occurrence] {
        occurrences.enumerated().sorted { lhs, rhs in
            let left = lhs.element.time?.milliseconds ?? -1
            let right = rhs.element.time?.milliseconds ?? -1
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}

// MARK: - Text mit Herkunft

/// Ein Text, in dem gesucht wird, mit der Herkunft jeder Stelle.
struct Document {
    let text: String
    let origin: Mention.Occurrence.Origin
    /// Transkript: UTF-16-Anfang und Länge jedes Segments und seine Zeit.
    private let starts: [Int]
    private let lengths: [Int]
    private let times: [MediaTime]

    /// Transkript: Segmente mit Leerzeichen verbunden, damit ein Name oder
    /// ein Termin über eine Segmentgrenze hinweg erkannt wird.
    init?(segments: [TranscriptSegment]) {
        var text = ""
        var starts: [Int] = []
        var lengths: [Int] = []
        var times: [MediaTime] = []
        var offset = 0
        for segment in segments.sorted(by: { $0.range.start < $1.range.start }) {
            let line = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if !text.isEmpty { text += " "; offset += 1 }
            starts.append(offset)
            let length = line.utf16.count
            lengths.append(length)
            times.append(segment.range.start)
            text += line
            offset += length
        }
        guard !text.isEmpty else { return nil }
        self.text = text; self.origin = .transcript
        self.starts = starts; self.lengths = lengths; self.times = times
    }

    /// Shownotes: Links bleiben als Adresse im Text, auch wenn die
    /// Beschriftung sie nicht nennt. Absätze und Listenpunkte werden Zeilen.
    init?(shownotes html: String) {
        var text = html
        if let anchor = Self.anchorPattern {
            let ns = text as NSString
            var output = ""
            var cursor = 0
            for match in anchor.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let href = EpisodeArchive.plainText(ns.substring(with: match.range(at: 1)))
                    .trimmingCharacters(in: .whitespaces)
                let label = EpisodeArchive.plainText(ns.substring(with: match.range(at: 2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lowerHref = href.lowercased()
                if lowerHref.hasPrefix("mailto:") {
                    let address = String(href.dropFirst(7))
                    let named = !address.isEmpty && label.lowercased().contains(address.lowercased())
                    output += named ? label : label.isEmpty ? " \(address) " : "\(label) (\(address))"
                } else if lowerHref.hasPrefix("http") {
                    output += Self.linkText(label: label, href: href)
                } else {
                    output += label
                }
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            text = output
        }
        text = text
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(p|div|li|h[1-6]|ul|ol|tr|blockquote)>"#, with: "\n",
                                  options: [.regularExpression, .caseInsensitive])
        text = EpisodeArchive.plainText(text)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        self.text = lines.joined(separator: "\n"); self.origin = .shownotes
        self.starts = []; self.lengths = []; self.times = []
    }

    /// Der Text für einen Link mit Beschriftung. Das Ziel ist immer die
    /// ganze Adresse aus `href`, mit Pfad und Schema, nie nur die Domain.
    ///
    /// Nennt die Beschriftung die Domain, etwa „Bericht auf heise.de“ oder
    /// eine gekürzte Adresse wie „https://example.org/lange/pa…“, tritt die
    /// ganze Adresse an die Stelle dieses Worts. Sonst fände die Erkennung
    /// die Domain allein und daneben den eigentlichen Artikel. Andere
    /// Beschriftungen bekommen die Adresse in Klammern dahinter.
    private static func linkText(label: String, href: String) -> String {
        guard !label.isEmpty else { return " \(href) " }
        let host = URL(string: href)?.host(percentEncoded: false)?.lowercased() ?? ""
        let domain = host.isEmpty ? "" : MentionExtractor.baseDomain(host)
        guard !domain.isEmpty else { return "\(label) (\(href))" }
        var words = label.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let index = words.firstIndex(where: { $0.lowercased().contains(domain) }) else {
            return "\(label) (\(href))"
        }
        // Satzzeichen hinter dem Wort bleiben stehen: „auf heise.de.“
        let word = words[index]
        let trailing = word.reversed().prefix { ".,;:!?)".contains($0) }
        words[index] = " \(href) " + String(trailing.reversed())
        return words.joined(separator: " ")
    }

    private static let anchorPattern = try? NSRegularExpression(
        pattern: #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// Welches Segment enthält die Stelle? Nur im Transkript.
    private func segmentIndex(at location: Int) -> Int? {
        guard !starts.isEmpty else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Die Grenzen, in denen der Zusammenhang steht: das Segment oder die Zeile.
    private func bounds(at location: Int) -> NSRange {
        let ns = text as NSString
        if let index = segmentIndex(at: location) {
            return NSRange(location: starts[index], length: lengths[index])
        }
        var start = location
        while start > 0, ns.character(at: start - 1) != 10 { start -= 1 }
        var end = min(location, ns.length)
        while end < ns.length, ns.character(at: end) != 10 { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    func occurrence(at range: NSRange) -> Mention.Occurrence {
        let time = segmentIndex(at: range.location).map { times[$0] }
        return Mention.Occurrence(origin: origin, time: time, context: snippet(for: range))
    }

    /// Höchstens etwa 160 Zeichen um die Stelle, an Wortgrenzen gekürzt.
    private func snippet(for range: NSRange) -> String {
        let ns = text as NSString
        let limit = 160
        let bounds = bounds(at: range.location)
        guard bounds.length > limit else {
            return ns.substring(with: bounds).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let spare = max(0, limit - range.length) / 2
        var start = max(bounds.location, range.location - spare)
        var end = min(bounds.location + bounds.length, range.location + range.length + spare)
        while start > bounds.location, !Self.isSpace(ns.character(at: start - 1)) { start -= 1 }
        while end < bounds.location + bounds.length, !Self.isSpace(ns.character(at: end)) { end += 1 }
        var result = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if start > bounds.location { result = "…" + result }
        if end < bounds.location + bounds.length { result += "…" }
        return result
    }

    /// Text um eine Stelle, für Hinweiswörter wie „Telefon“.
    func window(around range: NSRange, radius: Int) -> String {
        let ns = text as NSString
        let start = max(0, range.location - radius)
        let end = min(ns.length, range.location + range.length + radius)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// Steht die Stelle am Anfang eines Satzes, einer Zeile oder eines Segments?
    func isSentenceInitial(_ location: Int) -> Bool {
        if starts.contains(location) { return true }
        let ns = text as NSString
        var index = location - 1
        while index >= 0, Self.isSpace(ns.character(at: index)) {
            if ns.character(at: index) == 10 { return true }
            index -= 1
        }
        guard index >= 0 else { return true }
        let previous = Character(UnicodeScalar(ns.character(at: index)) ?? " ")
        return ".!?:;\"„“»«(•-–".contains(previous)
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 10 || unit == 9 || unit == 13 || unit == 160
    }
}
