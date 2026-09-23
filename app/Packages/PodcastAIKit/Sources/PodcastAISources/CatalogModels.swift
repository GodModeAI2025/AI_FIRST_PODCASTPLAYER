//
//  CatalogModels.swift
//  PodcastAISources
//
//  Was der Podcast-Katalog zeigt: Podcasts aus Apple Podcasts und aus der
//  Suche von Podcast Index, und die Regeln, nach denen Treffer aus beiden
//  zusammenkommen.
//
//  Alles hier ist fremde Eingabe. Titel und Beschreibungen kommen als
//  reiner Text an, ohne HTML, und gehen an kein Sprachmodell. Adressen
//  werden geprüft, bevor die App sie je aufruft.
//

import Foundation
import PodcastAICore

/// Ein Podcast aus dem Katalog, egal ob aus den Charts, der Suche bei
/// Apple oder der Suche bei Podcast Index.
public struct CatalogPodcast: Sendable, Hashable, Identifiable {

    public enum Origin: String, Sendable, Hashable {
        case appleDirectory
        case podcastIndex
    }

    public var origin: Origin
    /// Kennung im Apple-Podcast-Verzeichnis.
    public var itunesID: Int?
    public var title: String
    public var author: String
    public var feedURL: URL
    /// Weitere Schreibweisen des Feeds, die beim Zusammenführen aufgefallen
    /// sind, etwa die Adresse, unter der Podcast Index ihn führt.
    public var alternateFeedURLs: [URL]
    /// Schon auf https gehoben und geprüft, siehe `CatalogText.safeURL`.
    public var artworkURL: URL?
    /// Reiner Text ohne HTML. Die Charts einer Rubrik bringen ihn mit, die
    /// Seite des Podcasts liest ihn sonst aus dem Feed.
    public var summary: String?
    /// Die erste Rubrik laut Apple, schon in der Sprache des Landes.
    public var genre: String?
    /// Alle Rubriken laut Apple, in der Sprache des Landes, ohne „Podcasts“.
    public var genres: [String]
    /// Apples Kennungen der Rubriken, die wichtigste zuerst.
    public var genreIDs: [Int]
    public var isExplicit: Bool
    public var episodeCount: Int?
    public var newestEpisodeDate: Date?

    public var id: URL { feedURL }

    public init(
        origin: Origin, itunesID: Int? = nil, title: String, author: String, feedURL: URL,
        alternateFeedURLs: [URL] = [], artworkURL: URL? = nil, summary: String? = nil,
        genre: String? = nil, genres: [String] = [], genreIDs: [Int] = [],
        isExplicit: Bool = false, episodeCount: Int? = nil, newestEpisodeDate: Date? = nil
    ) {
        self.origin = origin
        self.itunesID = itunesID
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.alternateFeedURLs = alternateFeedURLs
        self.artworkURL = artworkURL
        self.summary = summary
        self.genre = genre
        self.genres = genres
        self.genreIDs = genreIDs
        self.isExplicit = isExplicit
        self.episodeCount = episodeCount
        self.newestEpisodeDate = newestEpisodeDate
    }

    /// Die Kategorien des Katalogs, zu denen der Podcast gehört.
    public var categories: [CatalogCategory] { CatalogCategory.categories(for: genreIDs) }

    /// Alle Feed-Adressen, unter denen jemand den Podcast abonniert haben kann.
    public var knownFeedURLs: [URL] { [feedURL] + alternateFeedURLs }
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
        text = text.replacingOccurrences(of: #"(?s)<(script|style)[^>]*>.*?</\1>"#, with: "",
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
        // Die alten Großschreibungen, die HTML noch kennt.
        ("&LT;", "<"), ("&GT;", ">"), ("&QUOT;", "\""),
        // Zuletzt, damit „&amp;lt;“ als „&lt;“ stehen bleibt.
        ("&amp;", "&"), ("&AMP;", "&"),
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = decodeNumericEntities(text)
        for (entity, value) in namedEntities {
            // Namen von Entitäten unterscheiden Groß und Klein: „&Uuml;“ ist „Ü“.
            result = result.replacingOccurrences(of: entity, with: value)
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

// MARK: - Zwei Verzeichnisse, eine Trefferliste

public enum CatalogMerge {

    /// Führt zwei Trefferlisten zusammen, etwa die Suche bei Apple und die
    /// bei Podcast Index.
    ///
    /// Die Listen werden im Wechsel gelesen, damit die besten Treffer beider
    /// vorn stehen. Derselbe Podcast, erkannt an der Feed-Adresse oder an
    /// der Apple-Kennung, erscheint nur einmal; was dem ersten Eintrag
    /// fehlt, ergänzt der zweite.
    public static func merged(_ first: [CatalogPodcast], _ second: [CatalogPodcast]) -> [CatalogPodcast] {
        var result: [CatalogPodcast] = []
        var positions: [String: Int] = [:]
        for position in 0..<max(first.count, second.count) {
            for list in [first, second] where position < list.count {
                let candidate = list[position]
                let keys = keys(for: candidate)
                if let existing = keys.lazy.compactMap({ positions[$0] }).first {
                    // Apples Eintrag trägt Datum und Rubriken in der Sprache
                    // des Landes. Er ist die Grundlage, egal welche Liste
                    // den Podcast zuerst nannte.
                    let present = result[existing]
                    result[existing] = present.origin == .podcastIndex && candidate.origin == .appleDirectory
                        ? filled(candidate, from: present) : filled(present, from: candidate)
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
        merged.itunesID = base.itunesID ?? other.itunesID
        // Die Schreibweisen des anderen Eintrags bleiben erhalten, damit ein
        // Abo unter seiner Adresse als Abo erkannt wird.
        for url in other.knownFeedURLs {
            let key = feedKey(url)
            if !merged.knownFeedURLs.contains(where: { feedKey($0) == key }) {
                merged.alternateFeedURLs.append(url)
            }
        }
        merged.artworkURL = base.artworkURL ?? other.artworkURL
        merged.summary = base.summary ?? other.summary
        merged.genre = base.genre ?? other.genre
        merged.episodeCount = base.episodeCount ?? other.episodeCount
        merged.newestEpisodeDate = base.newestEpisodeDate ?? other.newestEpisodeDate
        if merged.genres.isEmpty { merged.genres = other.genres }
        if merged.genreIDs.isEmpty { merged.genreIDs = other.genreIDs }
        if merged.author.isEmpty { merged.author = other.author }
        merged.isExplicit = base.isExplicit || other.isExplicit
        return merged
    }
}
