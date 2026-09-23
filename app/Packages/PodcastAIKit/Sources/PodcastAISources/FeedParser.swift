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
    /// einlesen darf keine zweite Folge erzeugen.
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

    public func parse(_ data: Data) throws -> ParsedFeed {
        guard !data.isEmpty else { throw FeedParseError.empty }
        guard data.count <= Self.maximumBytes else {
            throw FeedParseError.tooLarge(bytes: data.count)
        }

        let delegate = FeedParserDelegate()
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

    private var elementStack: [String] = []
    private var text = ""
    private var currentItem: ParsedItem?
    private var inImage = false
    private var itemCount = 0

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
    }

    func finish() -> ParsedFeed {
        var result = feed
        result.items = result.items.filter(\.isUsable)
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

        case (_, "image"):
            inImage = true

        case (_, "enclosure"):
            // RSS-Audioanhang.
            if attributeDict["type"]?.lowercased().hasPrefix("audio") ?? false,
               let url = Self.url(attributeDict["url"]) {
                currentItem?.audioURL = url
                currentItem?.audioMimeType = attributeDict["type"]
                currentItem?.audioByteCount = attributeDict["length"].flatMap(Int64.init)
            }

        case (NS.media, "content"):
            if let type = attributeDict["type"]?.lowercased(), type.hasPrefix("audio"),
               let url = Self.url(attributeDict["url"]) {
                currentItem?.audioURL = url
                currentItem?.audioMimeType = type
            }

        case (NS.media, "thumbnail"):
            if let url = Self.url(attributeDict["url"]) {
                if isInsideItem { currentItem?.artworkURL = url } else { feed.artworkURL = url }
            }

        case (NS.itunes, "image"):
            if let url = Self.url(attributeDict["href"]) {
                if isInsideItem { currentItem?.artworkURL = url } else { feed.artworkURL = url }
            }

        case (NS.psc, "chapter"):
            if let start = attributeDict["start"].flatMap(Self.chapterTime),
               let title = attributeDict["title"], !title.isEmpty {
                currentItem?.chapters.append(Chapter(start: start, title: title, provenance: .original))
            }

        case (NS.podcast20, "chapters"):
            if let url = Self.url(attributeDict["url"]) { currentItem?.chaptersURL = url }

        case (NS.podcast20, "transcript"):
            if let url = Self.url(attributeDict["url"]), let type = attributeDict["type"] {
                currentItem?.transcripts.append(
                    ParsedTranscriptRef(url: url, mimeType: type, language: attributeDict["language"])
                )
            }

        case (NS.atom, "link"):
            let rel = attributeDict["rel"] ?? "alternate"
            guard let href = Self.url(attributeDict["href"]) else { break }
            switch rel {
            case "alternate":
                if isInsideItem { currentItem?.webPageURL = href } else { feed.websiteURL = href }
            case "next":
                // Paginiertes Archiv: hier endet das Feedfenster, nicht das Archiv.
                if !isInsideItem { feed.nextPageURL = href }
            case "enclosure":
                if attributeDict["type"]?.lowercased().hasPrefix("audio") ?? false {
                    currentItem?.audioURL = href
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
        // Obergrenze je Textknoten gegen entartete Dokumente.
        guard text.count < 1_000_000 else { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        guard text.count < 1_000_000 else { return }
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
                // Ohne GUID die stabilste verfügbare Ersatzkennung bilden.
                if item.guid == nil {
                    item.guid = item.audioURL?.absoluteString
                        ?? item.webPageURL?.absoluteString
                        ?? item.youTubeVideoID
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
            guard let url = Self.url(value) else { break }
            if isInsideItem { currentItem?.webPageURL = url }
            else if !inImage { feed.websiteURL = url }

        case (_, "guid"), (NS.atom, "id"), (NS.yt, "videoid"):
            if isInsideItem, currentItem?.guid == nil { currentItem?.guid = value }
            if namespaceURI == NS.yt { currentItem?.youTubeVideoID = value }

        case (NS.content, "encoded"):
            if isInsideItem, !value.isEmpty { currentItem?.shownotesHTML = value }

        case (_, "description"), (NS.atom, "summary"), (NS.itunes, "summary"), (NS.media, "description"):
            if isInsideItem {
                if currentItem?.summary?.isEmpty ?? true { currentItem?.summary = value }
            } else if feed.summary?.isEmpty ?? true {
                feed.summary = value
            }

        case (_, "pubdate"), (NS.atom, "published"), (NS.atom, "updated"):
            if isInsideItem, currentItem?.publishedAt == nil {
                currentItem?.publishedAt = FeedDateParser.date(from: value)
            }

        case (NS.itunes, "duration"):
            currentItem?.duration = FeedDateParser.durationSeconds(from: value)

        case (NS.itunes, "author"), (_, "managingeditor"):
            if !isInsideItem, feed.author == nil { feed.author = value }

        case (NS.atom, "name"):
            if !isInsideItem, feed.author == nil, elementStack.contains("author") {
                feed.author = value
            }

        case (_, "language"):
            if !isInsideItem { feed.language = value }

        case (_, "url"):
            // `<image><url>` in RSS.
            if inImage, !isInsideItem, let url = Self.url(value) { feed.artworkURL = url }

        default:
            break
        }
    }

    /// Nur `http` und `https`. Ein Feed darf keine `file:`- oder
    /// `javascript:`-Verweise in die App tragen.
    /// Podlove-Zeitangaben: `01:02:03.500`, `02:03` oder Sekunden.
    static func chapterTime(_ raw: String) -> MediaTime? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return MediaTime(milliseconds: Int64((seconds * 1000).rounded()))
    }

    private static func url(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
