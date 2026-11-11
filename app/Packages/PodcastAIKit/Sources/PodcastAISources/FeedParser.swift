//
//  FeedParser.swift
//  PodcastAISources
//
//  RSS 2.0 und Atom in einem Durchlauf, mit iTunes- und Podcasting-2.0-
//  Namespaces. Gehärtet, weil ein Feed fremder Input ist:
//
//    - externe Entitäten aus (XXE),
//    - Größen- und Elementlimits gegen entartete Dokumente,
//    - Namespaces getrennt behandelt statt nach Präfix geraten,
//    - keine Auflösung von Netzwerkverweisen während des Parsens.
//
//  Ein Feedtext ist Daten. Er ist niemals eine Anweisung — weder an den
//  Parser noch später an ein Modell.
//

import Foundation
import PodcastAICore

public struct ParsedFeed: Sendable, Equatable {
    public var title: String
    public var author: String?
    public var summary: String?
    public var websiteURL: URL?
    public var artworkURL: URL?
    public var language: String?
    /// Rubriken aus `itunes:category` samt Unterrubriken und aus `<category>`,
    /// flach und ohne Doppelte, die übergeordnete vor der untergeordneten.
    public var categories: [String] = []
    /// `itunes:explicit`, `nil`, wenn der Feed nichts dazu sagt.
    public var isExplicit: Bool?
    public var items: [ParsedItem]
    /// Link auf die nächste Seite eines paginierten Archivs (RFC 5005).
    /// Macht den Unterschied zwischen Feedfenster und Gesamtarchiv.
    public var nextPageURL: URL?

    public init(
        title: String = "", author: String? = nil, summary: String? = nil,
        websiteURL: URL? = nil, artworkURL: URL? = nil, language: String? = nil,
        items: [ParsedItem] = [], nextPageURL: URL? = nil
    ) {
        self.title = title; self.author = author; self.summary = summary
        self.websiteURL = websiteURL; self.artworkURL = artworkURL
        self.language = language; self.items = items; self.nextPageURL = nextPageURL
    }
}

public struct ParsedItem: Sendable, Equatable {
    /// Stabile Kennung aus dem Feed. Grundlage der Deduplizierung — zweimal
    /// einlesen darf keine zweite Folge erzeugen. `nil`, wenn der Feed
    /// dieselbe GUID an Folgen mit verschiedenen Audiodateien vergibt; dann
    /// zählt die Audioadresse.
    public var guid: String?
    public var title: String
    public var summary: String?
    public var publishedAt: Date?
    public var duration: MediaDurationSeconds?
    /// Die Audiodatei aus `<enclosure>` bzw. `<media:content>`.
    public var audioURL: URL?
    public var audioByteCount: Int64?
    public var audioMimeType: String?
    public var webPageURL: URL?
    public var artworkURL: URL?
    /// Vom Anbieter bereitgestelltes Transkript (Podcasting 2.0).
    /// Der kürzeste Weg zu Timecodes ohne eigene Analyse.
    public var transcripts: [ParsedTranscriptRef]
    /// YouTube-Video-Kennung, sofern es sich um einen YouTube-Eintrag handelt.
    public var youTubeVideoID: String?
    /// Kapitel direkt im Feed (Podlove Simple Chapters).
    public var chapters: [Chapter] = []
    /// Kapitel als eigene JSON-Datei (`podcast:chapters`).
    public var chaptersURL: URL?
    /// Ausführliche Shownotes als HTML (`content:encoded`).
    public var shownotesHTML: String?
    /// Autor der Folge (`itunes:author` oder `dc:creator`).
    public var author: String?
    /// `itunes:episode` und `itunes:season`, nur positive Zahlen.
    public var episodeNumber: Int?
    public var season: Int?
    /// `itunes:episodeType`: full, trailer oder bonus.
    public var episodeType: String?
    /// Stichworte aus `itunes:keywords` und `<category>` der Folge.
    public var keywords: [String] = []

    public init(
        guid: String? = nil, title: String = "", summary: String? = nil,
        publishedAt: Date? = nil, duration: MediaDurationSeconds? = nil,
        audioURL: URL? = nil, audioByteCount: Int64? = nil, audioMimeType: String? = nil,
        webPageURL: URL? = nil, artworkURL: URL? = nil,
        transcripts: [ParsedTranscriptRef] = [], youTubeVideoID: String? = nil
    ) {
        self.guid = guid; self.title = title; self.summary = summary
        self.publishedAt = publishedAt; self.duration = duration
        self.audioURL = audioURL; self.audioByteCount = audioByteCount
        self.audioMimeType = audioMimeType; self.webPageURL = webPageURL
        self.artworkURL = artworkURL; self.transcripts = transcripts
        self.youTubeVideoID = youTubeVideoID
    }

    /// Das Anbietertranskript mit Zeitmarken, das die App zuerst nimmt:
    /// WebVTT, dann SRT, dann JSON. VTT und SRT sind am weitesten verbreitet
    /// und am einfachsten sicher zu lesen.
    public var preferredTimedTranscript: ParsedTranscriptRef? {
        let timed = transcripts.filter(\.isTimed)
        func rank(_ ref: ParsedTranscriptRef) -> Int {
            let type = ref.mimeType.lowercased()
            if type.contains("vtt") { return 0 }
            if type.contains("srt") || type.contains("subrip") { return 1 }
            return 2
        }
        return timed.min { rank($0) < rank($1) }
    }

    /// Ein Eintrag ohne Titel und ohne Medium ist kein brauchbarer Eintrag.
    public var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (audioURL != nil || youTubeVideoID != nil || webPageURL != nil)
    }
}

public struct ParsedTranscriptRef: Sendable, Equatable {
    public let url: URL
    public let mimeType: String
    public let language: String?

    public init(url: URL, mimeType: String, language: String? = nil) {
        self.url = url; self.mimeType = mimeType; self.language = language
    }

    /// Trägt dieses Format Zeitmarken? SRT und VTT ja, reiner Text nein.
    public var isTimed: Bool {
        let type = mimeType.lowercased()
        return type.contains("vtt") || type.contains("srt")
            || type.contains("subrip") || type.contains("json")
    }
}

/// Sekundenwert aus dem Feed, noch ungeprüft. Wird erst in der Domäne zu
/// einer ``MediaDuration`` — ein `<itunes:duration>` ist eine Behauptung des
/// Anbieters, keine gemessene Länge.
public typealias MediaDurationSeconds = Int

public enum FeedParseError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge(bytes: Int)
    case malformed(String)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .empty: String(localized: "Der Feed ist leer.", bundle: .module)
        case .tooLarge(let bytes):
            String(localized: "Der Feed ist zu groß (\(Int64(bytes).formatted(.byteCount(style: .file)))).",
                   bundle: .module)
        case .malformed(let detail): String(localized: "Der Feed konnte nicht gelesen werden: \(detail)", bundle: .module)
        case .unsupportedFormat: String(localized: "Dieses Format wird nicht unterstützt.", bundle: .module)
        }
    }
}

public struct FeedParser: Sendable {

    /// Obergrenze für ein einzelnes Feed-Dokument. Großzügig für echte
    /// Archive, eng genug gegen entartete Eingaben. Dieselbe Grenze wie
    /// beim Laden, sonst scheitert ein Feed, der vollständig geladen wurde,
    /// erst hier.
    public static let maximumBytes = Int(SafeHTTP.feedLimit)
    /// Obergrenze für Einträge je Dokument.
    public static let maximumItems = 5_000

    public init() {}

    /// `baseURL` ist die Adresse, von der der Feed kam. Relative Verweise wie
    /// `/media/ep1.mp3` oder `../ep1.mp3` werden dagegen aufgelöst; ohne sie
    /// fallen sie wie bisher weg. `xml:base` wird nicht ausgewertet.
    public func parse(_ data: Data, baseURL: URL? = nil) throws -> ParsedFeed {
        guard !data.isEmpty else { throw FeedParseError.empty }
        guard data.count <= Self.maximumBytes else {
            throw FeedParseError.tooLarge(bytes: data.count)
        }

        let delegate = FeedParserDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // XXE-Abwehr: keine externen Entitäten, kein Netzwerkzugriff beim Parsen.
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription
                ?? String(localized: "unbekannter Fehler", bundle: .module)
            // Ein abgebrochener Parse kann trotzdem brauchbare Einträge geliefert
            // haben — ein einzelner kaputter Eintrag am Ende darf nicht das
            // ganze Archiv wertlos machen.
            if !delegate.feed.items.isEmpty { return delegate.finish() }
            throw FeedParseError.malformed(message)
        }
        guard delegate.sawFeedRoot else { throw FeedParseError.unsupportedFormat }
        return delegate.finish()
    }
}

// MARK: - Delegate

private final class FeedParserDelegate: NSObject, XMLParserDelegate {

    var feed = ParsedFeed()
    var sawFeedRoot = false

    /// Die Adresse des Feeds, gegen die relative Verweise aufgelöst werden.
    private let baseURL: URL?
    private var elementStack: [String] = []
    private var text = ""
    private var currentItem: ParsedItem?
    /// `updated` des laufenden Atom-Eintrags, falls `published` fehlt.
    private var updatedAt: Date?
    /// Audiodatei und Seite des laufenden Eintrags gelten erst seit den
    /// neueren Regeln: Anhang ohne Audiotyp, relative Adresse. Vorher hatte
    /// der Eintrag an der Stelle nichts.
    private var audioIsLate = false
    private var pageIsLate = false
    private var inImage = false
    private var itemCount = 0
    /// Höchstens so viele Rubriken und Stichworte, gegen entartete Feeds.
    private static let maximumTerms = 50

    /// Namespaces, die uns interessieren. Alles andere wird ignoriert statt
    /// nach Präfix geraten — `media:` bedeutet nicht überall dasselbe.
    private enum NS {
        static let itunes = "http://www.itunes.com/dtds/podcast-1.0.dtd"
        static let media = "http://search.yahoo.com/mrss/"
        static let podcast20 = "https://podcastindex.org/namespace/1.0"
        static let atom = "http://www.w3.org/2005/Atom"
        static let yt = "http://www.youtube.com/xml/schemas/2015"
        static let psc = "http://podlove.org/simple-chapters"
        static let content = "http://purl.org/rss/1.0/modules/content/"
        static let dc = "http://purl.org/dc/elements/1.1/"
    }

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func finish() -> ParsedFeed {
        var result = feed
        result.items = result.items.filter(\.isUsable)

        // Manche Hoster setzen bei jeder Folge dieselbe GUID ein, etwa die
        // Startseite. Steht eine GUID an Folgen mit verschiedenen
        // Audiodateien, unterscheidet sie nichts: sie fällt dort weg, und es
        // zählt wie ohne GUID die Audioadresse. Echte Doppelte, also gleiche
        // GUID und gleiche Datei, behalten sie.
        var audioByGUID: [String: Set<String>] = [:]
        for item in result.items {
            if let guid = item.guid, let audio = item.audioURL?.absoluteString {
                audioByGUID[guid, default: []].insert(audio)
            }
        }
        for index in result.items.indices where result.items[index].audioURL != nil {
            if let guid = result.items[index].guid, audioByGUID[guid, default: []].count > 1 {
                result.items[index].guid = nil
            }
        }
        return result
    }

    private var isInsideItem: Bool { currentItem != nil }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        elementStack.append(name)
        text = ""

        switch (namespaceURI, name) {
        case (_, "rss"), (NS.atom, "feed"), (_, "channel"):
            sawFeedRoot = true

        case (_, "item"), (NS.atom, "entry"):
            guard itemCount < FeedParser.maximumItems else {
                parser.abortParsing()
                return
            }
            itemCount += 1
            currentItem = ParsedItem()
            updatedAt = nil
            audioIsLate = false
            pageIsLate = false

        case (NS.itunes, "image"):
            // Vor dem allgemeinen `image`: sonst fing jenes auch
            // `itunes:image` ab, und dessen `href` ging verloren.
            if let url = resolved(attributeDict["href"]) {
                if isInsideItem { currentItem?.artworkURL = url } else { feed.artworkURL = url }
            }

        case (NS.itunes, "category"):
            // Verschachtelt: die Unterrubrik steht als Kind der Rubrik.
            if !isInsideItem, let text = attributeDict["text"] {
                Self.appendTerm(text, to: &feed.categories)
            }

        case (_, "image"):
            inImage = true

        case (_, "enclosure"):
            // RSS-Audioanhang.
            if takeAudio(attributeDict["url"], type: attributeDict["type"]) {
                currentItem?.audioMimeType = attributeDict["type"]
                currentItem?.audioByteCount = attributeDict["length"].flatMap(Int64.init)
            }

        case (NS.media, "content"):
            if let type = attributeDict["type"]?.lowercased(), type.hasPrefix("audio"),
               takeAudio(attributeDict["url"], type: type) {
                currentItem?.audioMimeType = type
            }

        case (NS.media, "thumbnail"):
            if let url = resolved(attributeDict["url"]) {
                if isInsideItem { currentItem?.artworkURL = url } else { feed.artworkURL = url }
            }

        case (NS.psc, "chapter"):
            if let start = attributeDict["start"].flatMap(Self.chapterTime),
               let title = attributeDict["title"], !title.isEmpty {
                currentItem?.chapters.append(Chapter(start: start, title: title, provenance: .original))
            }

        case (NS.podcast20, "chapters"):
            if let url = resolved(attributeDict["url"]) { currentItem?.chaptersURL = url }

        case (NS.podcast20, "transcript"):
            if let url = resolved(attributeDict["url"]), let type = attributeDict["type"] {
                currentItem?.transcripts.append(
                    ParsedTranscriptRef(url: url, mimeType: type, language: attributeDict["language"])
                )
            }

        case (NS.atom, "link"):
            let rel = attributeDict["rel"] ?? "alternate"
            guard let href = resolved(attributeDict["href"]) else { break }
            switch rel {
            case "alternate":
                if isInsideItem { takePage(href, raw: attributeDict["href"]) } else { feed.websiteURL = href }
            case "next":
                // Paginiertes Archiv: hier endet das Feedfenster, nicht das Archiv.
                if !isInsideItem { feed.nextPageURL = href }
            case "enclosure":
                if takeAudio(attributeDict["href"], type: attributeDict["type"]) {
                    currentItem?.audioMimeType = attributeDict["type"]
                }
            default:
                break
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Obergrenze je Textknoten gegen entartete Dokumente. In Bytes:
        // `count` liefe bei jedem Aufruf durch den ganzen Text, und der
        // Parser ruft für jede Entität und alle paar hundert Byte neu auf.
        guard text.utf8.count < 1_000_000 else { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        guard text.utf8.count < 1_000_000 else { return }
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        defer {
            if !elementStack.isEmpty { elementStack.removeLast() }
            text = ""
        }

        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (namespaceURI, name) {
        case (_, "item"), (NS.atom, "entry"):
            if var item = currentItem {
                if item.publishedAt == nil { item.publishedAt = updatedAt }
                // Ohne GUID die stabilste verfügbare Ersatzkennung bilden.
                // Was erst seit den neueren Regeln gilt, steht dabei hinten:
                // die Folge gab es vorher schon, etwa ohne Audio mit ihrer
                // Seite als Kennung, und die behält sie.
                if item.guid == nil {
                    let audio = item.audioURL?.absoluteString
                    let page = item.webPageURL?.absoluteString
                    item.guid = (audioIsLate ? nil : audio)
                        ?? (pageIsLate ? nil : page)
                        ?? item.youTubeVideoID
                        ?? audio ?? page
                }
                feed.items.append(item)
            }
            currentItem = nil

        case (_, "image"):
            inImage = false

        case (_, "title"):
            if isInsideItem { currentItem?.title = value }
            else if !inImage, feed.title.isEmpty { feed.title = value }

        case (_, "link"):
            // Atom-Links kommen über Attribute; hier nur der RSS-Textknoten.
            guard let url = resolved(value) else { break }
            if isInsideItem { takePage(url, raw: value) }
            else if !inImage { feed.websiteURL = url }

        case (_, "guid"), (NS.atom, "id"), (NS.yt, "videoid"):
            // Eine leere GUID ist keine: sonst hätten alle Folgen eines Feeds
            // mit `<guid></guid>` dieselbe Kennung.
            if isInsideItem, currentItem?.guid == nil, !value.isEmpty { currentItem?.guid = value }
            if namespaceURI == NS.yt { currentItem?.youTubeVideoID = value }

        case (NS.content, "encoded"):
            if isInsideItem, !value.isEmpty { currentItem?.shownotesHTML = value }

        case (_, "description"), (NS.atom, "summary"), (NS.itunes, "summary"), (NS.media, "description"):
            if isInsideItem {
                if currentItem?.summary?.isEmpty ?? true { currentItem?.summary = value }
            } else if feed.summary?.isEmpty ?? true {
                feed.summary = value
            }

        case (_, "pubdate"), (NS.atom, "published"):
            if isInsideItem, currentItem?.publishedAt == nil {
                currentItem?.publishedAt = FeedDateParser.date(from: value)
            }

        case (NS.atom, "updated"):
            // Nur Ersatz für ein fehlendes `published`. WordPress nennt
            // `updated` zuerst und setzt es bei jeder Korrektur neu; als Datum
            // der Folge erschiene ein alter Beitrag damit wieder als neu.
            if isInsideItem, updatedAt == nil { updatedAt = FeedDateParser.date(from: value) }

        case (NS.itunes, "duration"):
            currentItem?.duration = FeedDateParser.durationSeconds(from: value)

        case (NS.itunes, "author"), (_, "managingeditor"):
            if isInsideItem {
                if name == "author", !value.isEmpty { currentItem?.author = value }
            } else if feed.author == nil, !value.isEmpty {
                feed.author = value
            }

        case (NS.dc, "creator"):
            if isInsideItem, currentItem?.author == nil, !value.isEmpty { currentItem?.author = value }

        case (NS.itunes, "episode"):
            if let number = Int(value), number > 0 { currentItem?.episodeNumber = number }

        case (NS.itunes, "season"):
            if let number = Int(value), number > 0 { currentItem?.season = number }

        case (NS.itunes, "episodetype"):
            let type = value.lowercased()
            if ["full", "trailer", "bonus"].contains(type) { currentItem?.episodeType = type }

        case (NS.itunes, "keywords"):
            guard isInsideItem else { break }
            for keyword in value.split(separator: ",") {
                Self.appendTerm(String(keyword), to: &currentItem!.keywords)
            }

        case (NS.itunes, "explicit"):
            if !isInsideItem { feed.isExplicit = Self.explicitFlag(value) }

        case (nil, "category"), ("", "category"):
            // Einfaches RSS-`<category>`: beim Kanal eine Rubrik, bei der
            // Folge ein Stichwort.
            if isInsideItem {
                Self.appendTerm(value, to: &currentItem!.keywords)
            } else {
                Self.appendTerm(value, to: &feed.categories)
            }

        case (NS.atom, "name"):
            guard elementStack.contains("author"), !value.isEmpty else { break }
            if isInsideItem {
                if currentItem?.author == nil { currentItem?.author = value }
            } else if feed.author == nil {
                feed.author = value
            }

        case (_, "language"):
            if !isInsideItem { feed.language = value }

        case (_, "url"):
            // `<image><url>` in RSS.
            if inImage, !isInsideItem, let url = resolved(value) { feed.artworkURL = url }

        default:
            break
        }
    }

    /// Nimmt einen Anhang als Audiodatei des Eintrags, wenn er eine ist.
    ///
    /// Sagt der Typ „audio“ und ist die Adresse vollständig, gilt der Anhang
    /// wie bisher, und der letzte gewinnt. Neuer sind zwei Fälle: die
    /// relative Adresse, und der Anhang, dessen Typ fehlt oder nichts sagt
    /// (`application/octet-stream`); bei ihm entscheidet die Dateiendung.
    /// Beide füllen nur eine Lücke: hat der Eintrag schon eine Audiodatei,
    /// bleibt sie. `mp4` zählt über die Endung nicht, ohne Typ ist das im
    /// Feed meist ein Video.
    private func takeAudio(_ raw: String?, type: String?) -> Bool {
        guard let url = resolved(raw) else { return false }
        let type = type?.lowercased() ?? ""
        if type.hasPrefix("audio"), Self.url(raw) != nil {
            audioIsLate = false
        } else {
            let untyped = ["", "application/octet-stream"].contains(type.trimmingCharacters(in: .whitespaces))
            let byExtension = untyped && SourceResolver.looksLikeAudioURL(url)
                && url.pathExtension.lowercased() != "mp4"
            guard currentItem?.audioURL == nil, type.hasPrefix("audio") || byExtension else { return false }
            audioIsLate = true
        }
        currentItem?.audioURL = url
        return true
    }

    /// Die Seite der Folge. Eine relative Adresse füllt wie bei der
    /// Audiodatei nur eine Lücke.
    private func takePage(_ url: URL, raw: String?) {
        let late = Self.url(raw) == nil
        if late, currentItem?.webPageURL != nil { return }
        currentItem?.webPageURL = url
        pageIsLate = late
    }

    /// Wie `Self.url`, löst aber einen relativen Verweis gegen die Adresse
    /// des Feeds auf. Geprüft wird, was dabei herauskommt.
    ///
    /// Relativ ist nur, was mit `/`, `.` oder `?` beginnt. Feeds schreiben
    /// auch „siriusxm.com“ oder „www.example.com/folge.mp3“ und meinen eine
    /// Adresse ohne Schema, keinen Pfad neben dem Feed. Aufgelöst entstünde
    /// daraus eine Adresse, die es nicht gibt. So etwas fällt wie bisher weg.
    private func resolved(_ string: String?) -> URL? {
        if let url = Self.url(string) { return url }
        guard let baseURL, let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = string.first, "/.?".contains(first) else { return nil }
        return Self.url(URL(string: string, relativeTo: baseURL)?.absoluteString)
    }

    /// Nimmt eine Rubrik oder ein Stichwort auf: getrimmt, nicht leer, nicht
    /// doppelt (ohne Groß- und Kleinschreibung) und mit Obergrenze.
    private static func appendTerm(_ raw: String, to list: inout [String]) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 80, list.count < maximumTerms,
              !list.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        list.append(term)
    }

    /// `itunes:explicit` kennt „true“, „yes“, „explicit“ und „false“, „no“, „clean“.
    private static func explicitFlag(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "explicit": true
        case "false", "no", "clean": false
        default: nil
        }
    }

    /// Podlove-Zeitangaben: `01:02:03.500`, `02:03` oder Sekunden.
    static func chapterTime(_ raw: String) -> MediaTime? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite else { return nil }
            seconds = seconds * 60 + value
        }
        return MediaTime.fromUntrustedSeconds(seconds)
    }

    /// Nur `http` und `https`. Ein Feed darf keine `file:`- oder
    /// `javascript:`-Verweise in die App tragen.
    private static func url(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
