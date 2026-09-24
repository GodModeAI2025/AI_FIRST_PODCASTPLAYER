//
//  EpisodeLinkResolver.swift
//  PodcastAISources
//
//  Links, die eine einzelne Folge meinen: Apple Podcasts mit `?i=`,
//  Folgenseiten von Hostern, Overcast und Pocket Casts. Dazu die Angaben
//  einer YouTube-Seite für die Vorschau vor dem Abonnieren.
//
//  Alles hier ist netzfrei und arbeitet auf schon gelesenem Text. Den
//  Abruf macht der Aufrufer über `SafeHTTP`. Was eine Seite sagt, ist ein
//  Hinweis, keine Anweisung: gesucht wird damit nur eine Folge im Feed, und
//  angelegt wird nur, was der Feed selbst führt.
//

import Foundation
import PodcastAICore

// MARK: - Apple Podcasts

/// Podcast und Folge aus einem Link wie
/// `podcasts.apple.com/de/podcast/name/id1200361736?i=1000791084583`.
public struct AppleEpisodeReference: Sendable, Equatable {
    public let podcastID: String
    public let episodeID: String

    public init(podcastID: String, episodeID: String) {
        self.podcastID = podcastID
        self.episodeID = episodeID
    }
}

public enum EpisodeLinks {

    /// Hosts von Apple Podcasts, auch die alten Adressen über iTunes.
    public static func isApplePodcasts(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host.hasSuffix("podcasts.apple.com") || host == "itunes.apple.com"
    }

    /// Die Kennung des Podcasts aus `…/id1234567890`.
    public static func applePodcastID(in url: URL) -> String? {
        for part in url.pathComponents.reversed() where part.hasPrefix("id") {
            let digits = part.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return nil
    }

    /// Podcast und Folge, wenn der Link auf eine Folge zeigt. Ohne `?i=`
    /// meint er den Podcast, dann `nil`.
    public static func appleEpisode(in url: URL) -> AppleEpisodeReference? {
        guard isApplePodcasts(url), let podcast = applePodcastID(in: url),
              let episode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "i" })?.value,
              !episode.isEmpty, episode.count <= 20, episode.allSatisfy(\.isNumber)
        else { return nil }
        return AppleEpisodeReference(podcastID: podcast, episodeID: episode)
    }

    /// Die Adresse, unter der Apple die Folgen eines Podcasts nennt.
    /// Apple liefert höchstens 200 Folgen, die neuesten zuerst; eine Abfrage
    /// über die Kennung der Folge selbst bleibt leer.
    public static func appleEpisodeLookupURL(for reference: AppleEpisodeReference, country: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "id", value: reference.podcastID),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }
}

/// Was die Abfrage bei Apple zu einer Folge ergibt.
public struct AppleEpisodeLookup: Sendable, Equatable {
    public var feedURL: URL?
    public var podcastTitle: String?
    public var author: String?
    public var artworkURL: URL?
    /// Die Folge selbst, wenn sie unter den 200 neuesten ist.
    public var episode: EpisodeLocator?

    public init(feedURL: URL? = nil, podcastTitle: String? = nil, author: String? = nil,
                artworkURL: URL? = nil, episode: EpisodeLocator? = nil) {
        self.feedURL = feedURL; self.podcastTitle = podcastTitle; self.author = author
        self.artworkURL = artworkURL; self.episode = episode
    }

    /// Liest die Antwort von `lookup?entity=podcastEpisode`.
    public static func parse(_ data: Data, episodeID: String) throws -> AppleEpisodeLookup {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result = AppleEpisodeLookup()
        for row in response.results {
            let isEpisode = row.wrapperType == "podcastEpisode" || row.kind == "podcast-episode"
            if !isEpisode {
                result.feedURL = result.feedURL ?? row.feedUrl.flatMap(Self.webURL)
                result.podcastTitle = result.podcastTitle ?? row.collectionName
                result.author = result.author ?? row.artistName
                result.artworkURL = result.artworkURL ?? (row.artworkUrl600 ?? row.artworkUrl100).flatMap(Self.webURL)
                continue
            }
            guard let trackID = row.trackId, String(trackID) == episodeID else { continue }
            result.feedURL = result.feedURL ?? row.feedUrl.flatMap(Self.webURL)
            result.podcastTitle = result.podcastTitle ?? row.collectionName
            result.episode = EpisodeLocator(
                guids: [row.episodeGuid].compactMap { $0?.isEmpty == false ? $0 : nil },
                audioURLs: [row.episodeUrl].compactMap { $0.flatMap(Self.webURL) },
                title: row.trackName)
        }
        return result
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private struct Response: Decodable {
        let results: [Row]
    }

    private struct Row: Decodable {
        let wrapperType: String?
        let kind: String?
        let trackId: Int64?
        let trackName: String?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let episodeUrl: String?
        let episodeGuid: String?
        let artworkUrl100: String?
        let artworkUrl600: String?
    }
}

// MARK: - Eine Folge im Feed finden

/// Woran sich eine Folge im Feed erkennen lässt. Jede Angabe ist ein
/// Hinweis; welcher Eintrag passt, entscheidet ``EpisodeMatcher``.
public struct EpisodeLocator: Sendable, Equatable {
    public var guids: [String]
    public var audioURLs: [URL]
    public var pageURLs: [URL]
    public var title: String?

    public init(guids: [String] = [], audioURLs: [URL] = [], pageURLs: [URL] = [], title: String? = nil) {
        self.guids = guids; self.audioURLs = audioURLs; self.pageURLs = pageURLs; self.title = title
    }

    public var isEmpty: Bool {
        guids.isEmpty && audioURLs.isEmpty && pageURLs.isEmpty && (title?.isEmpty ?? true)
    }
}

public enum EpisodeMatcher {

    /// Der Eintrag im Feed, den der Hinweis meint, oder `nil`.
    ///
    /// Die Reihenfolge folgt der Verlässlichkeit: GUID, dann Audioadresse,
    /// dann die Webseite der Folge, zuletzt der Titel. Beim Titel zählt nur
    /// ein eindeutiger Treffer; zwei Folgen mit ähnlichem Namen sind kein
    /// Grund, eine davon zu raten. `feedWebsite` ist die Startseite des
    /// Podcasts. Sie ist keine Folgenseite, auch wenn manche Feeds sie bei
    /// jeder Folge als `<link>` angeben.
    public static func index(of locator: EpisodeLocator, in items: [ParsedItem], feedWebsite: URL? = nil) -> Int? {
        let guids = Set(locator.guids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if !guids.isEmpty, let hit = items.firstIndex(where: { $0.guid.map(guids.contains) ?? false }) {
            return hit
        }

        let audioKeys = locator.audioURLs.map(audioKey)
        if !audioKeys.isEmpty {
            if let hit = items.firstIndex(where: { item in
                guard let audio = item.audioURL else { return false }
                let key = audioKey(audio)
                return audioKeys.contains { sameAudio($0, key) }
            }) { return hit }
            // Nur der Dateiname, wenn er lang und eindeutig ist. Hoster
            // hängen Zähler davor, deren Pfad sich ändert.
            let names = Set(locator.audioURLs.map { $0.lastPathComponent.lowercased() }.filter { $0.count >= 16 })
            let byName = items.indices.filter { items[$0].audioURL.map { names.contains($0.lastPathComponent.lowercased()) } ?? false }
            if byName.count == 1 { return byName[0] }
        }

        let home = feedWebsite.map(pageKey)
        let pages = Set(locator.pageURLs.map(pageKey).filter { !$0.isEmpty && $0 != home && $0.contains("/") })
        if !pages.isEmpty, let hit = items.firstIndex(where: { item in
            guard let page = item.webPageURL else { return false }
            return pages.contains(pageKey(page))
        }) { return hit }

        guard let title = locator.title.map(normalizedTitle), !title.isEmpty else { return nil }
        let equal = items.indices.filter { normalizedTitle(items[$0].title) == title }
        if equal.count == 1 { return equal[0] }
        if equal.count > 1 { return nil }
        // Seiten schreiben oft den Namen des Podcasts dazu:
        // „AI to the DNA | Federated Learning …“.
        let contained = items.indices.filter {
            let candidate = normalizedTitle(items[$0].title)
            return candidate.count >= 12 && title.contains(candidate)
        }
        return contained.count == 1 ? contained[0] : nil
    }

    /// Host ohne `www.` und Pfad, klein geschrieben, ohne Abfrage.
    static func audioKey(_ url: URL) -> String {
        var host = (url.host() ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + url.path().lowercased()
    }

    /// Gleich, oder die eine Adresse ist die andere mit vorgeschaltetem
    /// Zähler: `dts.podtrac.com/redirect.mp3/host/datei.mp3` meint
    /// `host/datei.mp3`.
    static func sameAudio(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasSuffix("/" + rhs) || rhs.hasSuffix("/" + lhs)
    }

    /// Host ohne `www.`, Pfad ohne Schrägstrich am Ende, ohne Abfrage.
    static func pageKey(_ url: URL) -> String {
        var host = (url.host() ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path().lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    static func normalizedTitle(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Folgenseiten

/// Was eine Folgenseite über sich sagt: Feed, Folge und Bild. Podigee,
/// Transistor, Podlove und andere verlinken den Feed im Kopf und nennen
/// ihre eigene Adresse als `og:url` oder kanonische Adresse; das ist
/// zugleich der `<link>` der Folge im Feed. Overcast verlinkt den Podcast
/// über seine Apple-Kennung (`/itunes123…`) und spielt die Datei selbst ab.
public struct EpisodePageHints: Sendable, Equatable {
    public var locator: EpisodeLocator
    public var feedURLs: [URL]
    public var applePodcastID: String?
    public var artworkURL: URL?

    public init(locator: EpisodeLocator = EpisodeLocator(), feedURLs: [URL] = [],
                applePodcastID: String? = nil, artworkURL: URL? = nil) {
        self.locator = locator; self.feedURLs = feedURLs
        self.applePodcastID = applePodcastID; self.artworkURL = artworkURL
    }

    public static func parse(html: String, pageURL: URL) -> EpisodePageHints {
        let meta = PageMeta(html: html)
        var hints = EpisodePageHints()
        hints.feedURLs = FeedDiscovery.feedLinks(inHTML: html, base: pageURL)

        var pages = [pageURL]
        for key in ["og:url", "twitter:url"] {
            if let url = meta.url(key, base: pageURL) { pages.append(url) }
        }
        if let canonical = PageMeta.canonicalURL(in: html, base: pageURL) { pages.append(canonical) }
        hints.locator.pageURLs = unique(pages)

        var audio: [URL] = []
        for key in ["og:audio", "og:audio:url", "og:audio:secure_url", "twitter:player:stream"] {
            if let url = meta.url(key, base: pageURL) { audio.append(url) }
        }
        audio += PageMeta.audioSources(in: html, base: pageURL)
        hints.locator.audioURLs = unique(audio)

        var guids: [String] = []
        for key in ["podcast:guid", "podcast:episode:guid"] {
            if let value = meta.value(key) { guids.append(value) }
        }
        guids += PageMeta.captures(#"<podcast:guid[^>]*>\s*([^<\s]{4,200})\s*</podcast:guid>"#, in: html, limit: 2)
        // Apple und manche Player legen die GUID als JSON in die Seite.
        guids += PageMeta.captures(#""(?:episodeGuid|guid)"\s*:\s*"([^"\\]{4,200})""#, in: html, limit: 3)
        hints.locator.guids = Array(NSOrderedSet(array: guids).compactMap { $0 as? String })

        hints.locator.title = meta.value("og:title") ?? meta.value("twitter:title") ?? PageMeta.title(in: html)
        hints.artworkURL = meta.url("og:image", base: pageURL)
        hints.applePodcastID = PageMeta.captures(
            #"(?:podcasts\.apple\.com|itunes\.apple\.com)/[^"'\s<>]*?/id(\d{5,15})"#, in: html, limit: 1).first
            ?? PageMeta.captures(#"href=["']/itunes(\d{5,15})"#, in: html, limit: 1).first
        return hints
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { NetworkDestination.isAllowed($0) && seen.insert($0.absoluteString).inserted }
    }
}

// MARK: - YouTube-Seiten

/// Die Angaben einer YouTube-Seite, eines Kanals oder eines Videos, für
/// die Vorschau vor dem Abonnieren. Der Text ist fremd und wird nur
/// angezeigt.
public struct YouTubePageInfo: Sendable, Equatable {
    public var title: String?
    public var summary: String?
    public var imageURL: URL?
    public var channelID: String?
    public var publishedAt: Date?

    public init(title: String? = nil, summary: String? = nil, imageURL: URL? = nil,
                channelID: String? = nil, publishedAt: Date? = nil) {
        self.title = title; self.summary = summary; self.imageURL = imageURL
        self.channelID = channelID; self.publishedAt = publishedAt
    }

    public static func parse(html: String) -> YouTubePageInfo {
        let meta = PageMeta(html: html)
        let base = URL(string: "https://www.youtube.com/")!
        return YouTubePageInfo(
            title: meta.value("og:title"),
            summary: meta.value("og:description"),
            imageURL: meta.url("og:image", base: base),
            channelID: FeedDiscovery.youTubeChannelID(inHTML: html),
            publishedAt: (meta.value("datePublished") ?? meta.value("uploadDate")).flatMap(FeedDateParser.date(from:)))
    }

    /// Die Kanalkennung aus einem YouTube-Feed. Im Feed einer Playlist steht
    /// sie mit `UC`, im Feed eines Kanals auf Feedebene ohne; die Einträge
    /// tragen sie immer mit.
    public static func channelID(inFeed data: Data) -> String? {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        for candidate in PageMeta.captures(#"<yt:channelId>\s*([A-Za-z0-9_-]{22,24})\s*</yt:channelId>"#, in: text, limit: 4) {
            if FeedDiscovery.isChannelID(candidate) { return candidate }
            if candidate.count == 22, FeedDiscovery.isChannelID("UC" + candidate) { return "UC" + candidate }
        }
        return nil
    }

    /// Die Adresse der Kanalseite, auf der Name, Bild und Beschreibung stehen.
    public static func channelPageURL(channelID: String) -> URL? {
        guard FeedDiscovery.isChannelID(channelID) else { return nil }
        return URL(string: "https://www.youtube.com/channel/\(channelID)")
    }
}

// MARK: - Kopf einer Seite lesen

/// Die `<meta>`-Angaben aus dem Kopf einer Seite. Gelesen wird nur der
/// Kopf, wie bei der Feed-Suche.
struct PageMeta {
    private var values: [String: String] = [:]

    init(html: String) {
        let head: Substring
        if let end = html.range(of: "</head", options: .caseInsensitive) {
            head = html[html.startIndex..<end.lowerBound]
        } else {
            head = html.prefix(512 * 1024)
        }
        var remainder = head
        while let open = remainder.range(of: "<meta", options: .caseInsensitive) {
            let rest = remainder[open.lowerBound...]
            guard let close = rest.firstIndex(of: ">") else { break }
            let attributes = FeedDiscovery.attributes(in: String(rest[rest.startIndex...close]))
            if let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
               let content = attributes["content"], values[key] == nil {
                let decoded = FeedDiscovery.decodeEntities(content)
                if !decoded.isEmpty { values[key] = decoded }
            }
            remainder = rest[rest.index(after: close)...]
        }
    }

    func value(_ key: String) -> String? { values[key.lowercased()] }

    func url(_ key: String, base: URL) -> URL? {
        guard let raw = value(key), let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              NetworkDestination.isAllowed(url) else { return nil }
        return url
    }

    static func canonicalURL(in html: String, base: URL) -> URL? {
        for tag in FeedDiscovery.linkTags(in: html) {
            let attributes = FeedDiscovery.attributes(in: tag)
            guard attributes["rel"]?.lowercased() == "canonical", let href = attributes["href"],
                  let url = URL(string: FeedDiscovery.decodeEntities(href), relativeTo: base)?.absoluteURL,
                  NetworkDestination.isAllowed(url) else { continue }
            return url
        }
        return nil
    }

    static func title(in html: String) -> String? {
        captures(#"<title[^>]*>([^<]{1,300})</title>"#, in: String(html.prefix(256 * 1024)), limit: 1)
            .first.map(FeedDiscovery.decodeEntities)
    }

    /// `<audio src>`, `<source src>` und `<enclosure url>` mit Audio. Der
    /// Sprung im Player (`#t=0`) gehört nicht zur Adresse.
    static func audioSources(in html: String, base: URL) -> [URL] {
        var found: [URL] = []
        let pattern = #"<(audio|source|enclosure)\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range).prefix(40) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let attributes = FeedDiscovery.attributes(in: String(html[tagRange]))
            guard let raw = attributes["src"] ?? attributes["url"] else { continue }
            let type = attributes["type"]?.lowercased() ?? ""
            guard var components = URLComponents(string: FeedDiscovery.decodeEntities(raw)) else { continue }
            components.fragment = nil
            guard let url = components.url(relativeTo: base)?.absoluteURL,
                  NetworkDestination.isAllowed(url),
                  type.hasPrefix("audio") || SourceResolver.looksLikeAudioURL(url) else { continue }
            found.append(url)
        }
        return found
    }

    static func captures(_ pattern: String, in text: String, limit: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { continue }
            result.append(String(text[captured]))
            if result.count == limit { break }
        }
        return result
    }
}
