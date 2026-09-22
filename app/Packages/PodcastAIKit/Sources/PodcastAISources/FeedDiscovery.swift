//
//  FeedDiscovery.swift
//  PodcastAISources
//
//  Aus einem Link einen Feed machen.
//
//  `SourceResolver` erkannte YouTube-Videos, Playlists und gewöhnliche
//  Webseiten korrekt — und danach war Schluss: `addSource` warf „Zu diesem
//  Link muss erst der Feed ermittelt werden. Das ist noch nicht eingebaut“.
//  Drei von vier Wegen aus Kapitel 1 endeten damit in einer Fehlermeldung.
//
//  Die Ermittlung zerfällt in zwei Arten, und sie sind hier getrennt, weil
//  sie verschieden viel kosten:
//
//  * **Ohne Netz.** Eine YouTube-Playlist hat eine bekannte Feed-Adresse.
//    Dafür braucht es keine Anfrage, nur die Regel.
//  * **Mit Netz.** Eine Webseite muss gelesen werden, um ihren Feed zu
//    finden. Das Lesen selbst macht der Aufrufer über `SafeHTTP` — hier
//    steht nur, was in dem Gelesenen steht.
//
//  Das Zerlegen ist absichtlich eine reine Funktion über einen String: so
//  lässt es sich gegen echte Seiten prüfen, ohne eine Anfrage zu stellen.
//

import Foundation
import PodcastAICore

public enum FeedDiscovery {

    /// Die Feed-Adresse, die sich ohne Anfrage ergibt.
    ///
    /// Nur für Fälle, in denen die Adresse **regelhaft** feststeht. Raten
    /// gehört nicht dazu: ein Link, zu dem es keine bekannte Regel gibt,
    /// liefert `nil` und wird gelesen statt erraten.
    public static func directFeedURL(for link: ResolvedLink) -> URL? {
        switch link {
        case .podcastFeed(let url):
            return url
        case .youTubeChannel(_, let feedURL):
            return feedURL
        case .youTubePlaylist(let playlistID, _):
            // Dieselbe Form wie beim Kanal, mit `playlist_id` statt
            // `channel_id`. Eine öffentliche Playlist hat sie immer.
            return URL(string:
                "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistID)")
        case .youTubeVideo, .webPageNeedingDiscovery, .localFile, .audioFile:
            return nil
        }
    }

    /// Welche Seite gelesen werden muss, um weiterzukommen.
    ///
    /// Getrennt von `directFeedURL`, damit der Aufrufer nicht raten muss, ob
    /// eine Anfrage nötig ist.
    public static func pageToInspect(for link: ResolvedLink) -> URL? {
        switch link {
        case .webPageNeedingDiscovery(let url): url
        // Ein Video ist kein Feed. Was sich daraus gewinnen lässt, ist der
        // Kanal — und der wird abonniert, nicht das einzelne Video. Das
        // steht auch so in der Oberfläche.
        case .youTubeVideo(_, let watchURL, _): watchURL
        case .podcastFeed, .youTubeChannel, .youTubePlaylist, .localFile, .audioFile: nil
        }
    }

    /// Alle Feed-Verweise aus dem Kopf einer HTML-Seite, in der Reihenfolge
    /// ihres Vorkommens.
    ///
    /// Bewusst keine vollständige HTML-Zerlegung: gesucht wird genau das
    /// eine Element, das laut Konvention den Feed benennt. Was sonst auf der
    /// Seite steht, geht die App nichts an — und ein Zerleger, der mehr
    /// versteht, versteht auch mehr falsch.
    public static func feedLinks(inHTML html: String, base: URL) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()

        for tag in linkTags(in: html) {
            let attributes = self.attributes(in: tag)
            guard let rel = attributes["rel"]?.lowercased(),
                  rel.split(separator: " ").contains("alternate") else { continue }
            guard let type = attributes["type"]?.lowercased(),
                  feedTypes.contains(type) else { continue }
            guard let href = attributes["href"], !href.isEmpty else { continue }

            // Relative Adressen gegen die Seite auflösen — die meisten
            // Feed-Verweise stehen als `/feed.xml` dort.
            guard let url = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL
            else { continue }
            // Was nicht abgerufen werden dürfte, wird auch nicht vorgeschlagen.
            guard NetworkDestination.isAllowed(url) else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            found.append(url)
        }
        return found
    }

    /// Die Kanalkennung aus einer YouTube-Seite.
    ///
    /// Zwei Schreibweisen kommen auf derselben Seite vor; genommen wird die
    /// erste, die eine gültige Kennung ergibt. Eine YouTube-Kanalkennung
    /// beginnt mit `UC` und ist 24 Zeichen lang — das wird geprüft, statt
    /// irgendeine Zeichenfolge zu übernehmen.
    public static func youTubeChannelID(inHTML html: String) -> String? {
        let patterns = [
            #"<meta[^>]+itemprop=["']channelId["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+itemprop=["']channelId["']"#,
            #"["']channelId["']\s*:\s*["']([^"']+)["']"#,
            #"/channel/(UC[A-Za-z0-9_-]{22})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: html) else { continue }
                let candidate = String(html[captured])
                if isChannelID(candidate) { return candidate }
            }
        }
        return nil
    }

    public static func isChannelID(_ value: String) -> Bool {
        value.count == 24 && value.hasPrefix("UC")
            && value.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    public static func youTubeFeedURL(forChannel channelID: String) -> URL? {
        guard isChannelID(channelID) else { return nil }
        return URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")
    }

    // MARK: - Zerlegen

    static let feedTypes: Set<String> = [
        "application/rss+xml", "application/atom+xml",
        "application/rdf+xml", "application/feed+json", "application/json",
    ]

    /// Alle `<link …>`-Elemente. Nur bis zum Ende des Kopfes, sofern es
    /// einen gibt: ein `<link>` im Rumpf ist kein Feed-Verweis, und eine
    /// lange Seite muss nicht ganz durchsucht werden.
    static func linkTags(in html: String) -> [String] {
        let searchable: Substring
        if let headEnd = html.range(of: "</head", options: [.caseInsensitive]) {
            searchable = html[html.startIndex..<headEnd.lowerBound]
        } else {
            searchable = html[...]
        }

        var tags: [String] = []
        var remainder = searchable[...]
        while let open = remainder.range(of: "<link", options: [.caseInsensitive]) {
            let rest = remainder[open.lowerBound...]
            guard let close = rest.firstIndex(of: ">") else { break }

            // Nach dem Namen muss ein Trenner kommen. Sonst wäre `<linkage>`
            // ein `link`-Element — der Fehler, den ein zu williger Zerleger
            // macht und den man erst bemerkt, wenn eine Seite ihn enthält.
            let after = rest.index(open.lowerBound, offsetBy: 5)
            if after < rest.endIndex,
               rest[after].isWhitespace || rest[after] == ">" || rest[after] == "/" {
                tags.append(String(rest[rest.startIndex...close]))
            }
            remainder = rest[rest.index(after: close)...]
        }
        return tags
    }

    /// Attribute eines Elements als Paare. Einfache und doppelte
    /// Anführungszeichen, beliebige Reihenfolge.
    static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)

        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = String(tag[nameRange]).lowercased()
            let valueIndex = match.range(at: 3).location != NSNotFound ? 3 : 4
            guard let valueRange = Range(match.range(at: valueIndex), in: tag) else { continue }
            // Erste Nennung gewinnt: ein zweites `href` im selben Element ist
            // fehlerhaft, und das erste ist das, was ein Browser nimmt.
            if result[name] == nil { result[name] = String(tag[valueRange]) }
        }
        return result
    }

    /// Die fünf Entitäten, die in Adressen tatsächlich vorkommen.
    ///
    /// `&amp;` ist der Grund für diese Funktion: in HTML steht es überall
    /// dort, wo eine Adresse mehrere Parameter hat, und unaufgelöst zeigt
    /// der Link ins Leere.
    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [
            ("&amp;", "&"), ("&#38;", "&"), ("&#x26;", "&"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
        ] {
            result = result.replacingOccurrences(
                of: entity, with: character, options: [.caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
