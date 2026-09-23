//
//  CatalogModels.swift
//  PodcastAISources
//
//  Was der Podcast-Katalog zeigt: Podcasts, ihre neuesten Folgen und die
//  Regeln, nach denen Treffer aus zwei Verzeichnissen zusammenkommen.
//
//  Alles hier ist fremde Eingabe. Titel und Beschreibungen kommen als
//  reiner Text an, ohne HTML, und gehen an kein Sprachmodell. Adressen
//  werden geprüft, bevor die App sie je aufruft.
//

import Foundation
import PodcastAICore

/// Ein Podcast aus dem Katalog, egal ob Podcast Index oder das
/// Apple-Podcast-Verzeichnis ihn geliefert hat.
public struct CatalogPodcast: Sendable, Hashable, Identifiable {

    public enum Origin: String, Sendable, Hashable {
        case podcastIndex
        case appleDirectory
    }

    public var origin: Origin
    /// Kennung bei Podcast Index. Nur damit lassen sich Folgen und
    /// Einzelheiten aus dem Katalog nachladen.
    public var podcastIndexID: Int?
    /// Kennung im Apple-Podcast-Verzeichnis.
    public var itunesID: Int?
    public var podcastGUID: String?
    public var title: String
    public var author: String
    public var feedURL: URL
    /// Die Feed-Adresse vor einem Umzug. Wer den Podcast unter der alten
    /// Adresse abonniert hat, hat ihn trotzdem schon.
    public var originalFeedURL: URL?
    public var websiteURL: URL?
    /// Schon auf https gehoben und geprüft, siehe `CatalogText.safeURL`.
    public var artworkURL: URL?
    /// Reiner Text ohne HTML.
    public var summary: String?
    /// So, wie der Feed sie angibt, etwa „de“, „de-DE“ oder „en-us“.
    public var language: String?
    /// Kategorien von Podcast Index, aufsteigend.
    public var categoryIDs: [Int]
    /// Die Rubrik aus dem Apple-Verzeichnis, schon in der Sprache des Landes.
    public var genre: String?
    public var isExplicit: Bool
    public var episodeCount: Int?
    public var newestEpisodeDate: Date?

    public var id: URL { feedURL }

    public init(
        origin: Origin, podcastIndexID: Int? = nil, itunesID: Int? = nil, podcastGUID: String? = nil,
        title: String, author: String, feedURL: URL, originalFeedURL: URL? = nil,
        websiteURL: URL? = nil, artworkURL: URL? = nil, summary: String? = nil,
        language: String? = nil, categoryIDs: [Int] = [], genre: String? = nil,
        isExplicit: Bool = false, episodeCount: Int? = nil, newestEpisodeDate: Date? = nil
    ) {
        self.origin = origin
        self.podcastIndexID = podcastIndexID
        self.itunesID = itunesID
        self.podcastGUID = podcastGUID
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.originalFeedURL = originalFeedURL
        self.websiteURL = websiteURL
        self.artworkURL = artworkURL
        self.summary = summary
        self.language = language
        self.categoryIDs = categoryIDs
        self.genre = genre
        self.isExplicit = isExplicit
        self.episodeCount = episodeCount
        self.newestEpisodeDate = newestEpisodeDate
    }

    /// Die Rubriken des Katalogs, zu denen der Podcast gehört.
    public var categories: [CatalogCategory] { CatalogCategory.categories(for: categoryIDs) }

    /// Alle Feed-Adressen, unter denen jemand den Podcast abonniert haben kann.
    public var knownFeedURLs: [URL] { [feedURL] + (originalFeedURL.map { [$0] } ?? []) }
}

/// Eine Folge aus dem Katalog, nur zum Ansehen vor dem Abonnieren. Eine
/// Audio-Adresse trägt sie absichtlich nicht: aus dem Katalog wird nichts
/// abgespielt.
public struct CatalogEpisode: Sendable, Hashable, Identifiable {
    public let id: Int
    public var title: String
    public var publishedAt: Date?
    /// Sekunden, wie der Katalog sie schätzt. Fehlt oder 0 heißt: unbekannt.
    public var duration: Int?
    public var isExplicit: Bool
    public var season: Int?
    public var episodeNumber: Int?
    /// `full`, `trailer` oder `bonus`.
    public var episodeType: String?

    public init(id: Int, title: String, publishedAt: Date? = nil, duration: Int? = nil,
                isExplicit: Bool = false, season: Int? = nil, episodeNumber: Int? = nil,
                episodeType: String? = nil) {
        self.id = id
        self.title = title
        self.publishedAt = publishedAt
        self.duration = duration
        self.isExplicit = isExplicit
        self.season = season
        self.episodeNumber = episodeNumber
        self.episodeType = episodeType
    }
}

// MARK: - Text und Adressen

public enum CatalogText {

    /// Beschreibung als reiner Text: Tags weg, Entitäten aufgelöst, Absätze
    /// bleiben als Leerzeile. `nil`, wenn nichts übrig bleibt.
    public static func plain(_ html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(p|div|h[1-6]|ul|ol|blockquote)>"#, with: "\n\n",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // Skripte und Stile tragen keinen lesbaren Text.
        text = text.replacingOccurrences(of: #"<(script|style)[^>]*>.*?</\1>"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = decodeEntities(text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Ein Titel oder Name in einer Zeile: ohne Tags, ohne Umbrüche.
    public static func line(_ html: String?) -> String? {
        guard let html else { return nil }
        let text = decodeEntities(html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Eine Adresse aus fremden Daten, die die App aufrufen darf: http oder
    /// https, kein lokales Ziel, und schon auf https gehoben. Sonst `nil`.
    public static func safeURL(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
              let url = URL(string: string) ?? URL(string: string.replacingOccurrences(of: " ", with: "%20")),
              NetworkDestination.isAllowed(url) else { return nil }
        return SafeHTTP.secureVariant(of: url)
    }

    /// Eine Feed-Adresse. Bleibt, wie sie ist, auch mit http: an ihr hängen
    /// die Kennungen der Quelle, und das Abo stuft ohnehin selbst hoch.
    static func feedURL(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
              let url = URL(string: string), NetworkDestination.isAllowed(url) else { return nil }
        return url
    }

    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ("&apos;", "'"), ("&auml;", "ä"), ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"),
        ("&Ouml;", "Ö"), ("&Uuml;", "Ü"), ("&szlig;", "ß"), ("&ndash;", "–"), ("&mdash;", "—"),
        ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"),
        ("&bdquo;", "„"), ("&eacute;", "é"), ("&egrave;", "è"), ("&copy;", "©"),
        // Zuletzt, damit „&amp;lt;“ als „&lt;“ stehen bleibt.
        ("&amp;", "&"),
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = decodeNumericEntities(text)
        for (entity, value) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return result
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#([xX]?[0-9a-fA-F]{1,7});") else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let code = source.substring(with: match.range(at: 1))
            let value = code.lowercased().hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            // „&#38;“ bleibt als „&amp;“ stehen und wird unten wie die
            // anderen benannten Entitäten aufgelöst, nicht doppelt.
            if let value, value != 38, let scalar = Unicode.Scalar(value) {
                output += String(Character(scalar))
            } else if value == 38 {
                output += "&amp;"
            } else {
                output += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

// MARK: - Sprache

public enum CatalogLanguage {

    /// Werte für den Parameter `lang` bei den Trends. Die API nennt nicht,
    /// ob „de“ auch „de-DE“ trifft, deshalb stehen die üblichen Schreibweisen
    /// einzeln da.
    public static func codes(for language: AppLanguage) -> [String] {
        switch language {
        case .german: ["de", "de-de", "de-at", "de-ch"]
        case .english: ["en", "en-us", "en-gb", "en-au", "en-ca", "en-ie"]
        }
    }

    /// Ist der Podcast in dieser Sprache? Ohne Angabe im Feed: nein.
    public static func matches(_ feedLanguage: String?, _ language: AppLanguage) -> Bool {
        language.matches(feedLanguage?.replacingOccurrences(of: "_", with: "-")) == true
    }

    /// Nur die Podcasts in `language`. `nil` heißt: alle Sprachen.
    public static func filter(_ podcasts: [CatalogPodcast], language: AppLanguage?) -> [CatalogPodcast] {
        guard let language else { return podcasts }
        return podcasts.filter { matches($0.language, language) }
    }
}

// MARK: - Zwei Verzeichnisse, eine Trefferliste

public enum CatalogMerge {

    /// Führt die Treffer von Podcast Index und dem Apple-Verzeichnis zusammen.
    ///
    /// Die Listen werden im Wechsel gelesen, damit die besten Treffer beider
    /// vorn stehen. Derselbe Podcast, erkannt an der Feed-Adresse (auch der
    /// alten) oder an der Apple-Kennung, erscheint nur einmal; was dem ersten
    /// Eintrag fehlt, ergänzt der zweite.
    public static func merged(_ index: [CatalogPodcast], _ directory: [CatalogPodcast]) -> [CatalogPodcast] {
        var result: [CatalogPodcast] = []
        var positions: [String: Int] = [:]
        for position in 0..<max(index.count, directory.count) {
            for list in [index, directory] where position < list.count {
                let candidate = list[position]
                let keys = keys(for: candidate)
                if let existing = keys.lazy.compactMap({ positions[$0] }).first {
                    result[existing] = filled(result[existing], from: candidate)
                    for key in self.keys(for: result[existing]) { positions[key] = existing }
                } else {
                    result.append(candidate)
                    for key in keys { positions[key] = result.count - 1 }
                }
            }
        }
        return result
    }

    /// Schlüssel, an denen zwei Einträge als derselbe Podcast gelten.
    static func keys(for podcast: CatalogPodcast) -> [String] {
        var keys = podcast.knownFeedURLs.map(feedKey)
        if let itunes = podcast.itunesID { keys.append("itunes:\(itunes)") }
        return keys
    }

    /// Eine Feed-Adresse ohne das, worin sich zwei Schreibweisen desselben
    /// Feeds unterscheiden: Schema, `www.`, Groß- und Kleinschreibung des
    /// Hosts, Standard-Port und ein Schrägstrich am Ende.
    public static func feedKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if components.port == 80 || components.port == 443 { components.port = nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = components.port.map { ":\($0)" } ?? ""
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "feed:" + host + port + path + query
    }

    private static func filled(_ base: CatalogPodcast, from other: CatalogPodcast) -> CatalogPodcast {
        var merged = base
        merged.podcastIndexID = base.podcastIndexID ?? other.podcastIndexID
        merged.itunesID = base.itunesID ?? other.itunesID
        merged.podcastGUID = base.podcastGUID ?? other.podcastGUID
        merged.originalFeedURL = base.originalFeedURL ?? other.originalFeedURL
        merged.websiteURL = base.websiteURL ?? other.websiteURL
        merged.artworkURL = base.artworkURL ?? other.artworkURL
        merged.summary = base.summary ?? other.summary
        merged.language = base.language ?? other.language
        merged.genre = base.genre ?? other.genre
        merged.episodeCount = base.episodeCount ?? other.episodeCount
        merged.newestEpisodeDate = base.newestEpisodeDate ?? other.newestEpisodeDate
        if merged.categoryIDs.isEmpty { merged.categoryIDs = other.categoryIDs }
        if merged.author.isEmpty { merged.author = other.author }
        merged.isExplicit = base.isExplicit || other.isExplicit
        return merged
    }
}
