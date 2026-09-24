//
//  SupadataMetadata.swift
//  PodcastAISources
//
//  Metadaten eines Videos über Supadata: volle Beschreibung, Länge,
//  Datum, Kanal, Vorschaubild und Stichworte.
//
//  Der YouTube-Feed kürzt die Beschreibung und nennt keine Länge. Mit einem
//  eigenen Schlüssel füllt die App diese Lücken über `GET /v1/metadata`.
//  Die Regeln:
//
//  * Nur Lücken füllen. Was der Feed sagt, bleibt. Eine gekürzte
//    Beschreibung gilt als Lücke, wenn die volle mit ihr beginnt.
//  * Fremde Daten: der Text wird angezeigt und durchsucht, aber nie als
//    Anweisung gelesen. Titel und Adressen der Folge ändert er nicht.
//  * Die Herkunft bleibt sichtbar: „Metadaten über Supadata“.
//

import Foundation
import PodcastAICore

public struct SupadataMetadata: Codable, Hashable, Sendable {
    public var platform: String?
    public var videoID: String?
    public var title: String?
    public var description: String?
    public var authorName: String?
    /// Der Name des Kontos, etwa „imkerei“ ohne „@“.
    public var authorUsername: String?
    public var authorAvatarURL: URL?
    /// Die Adresse des Beitrags, wie Supadata sie nennt. Aus Kurzlinks wird
    /// so die volle Adresse.
    public var url: URL?
    public var duration: MediaDuration?
    public var thumbnailURL: URL?
    public var tags: [String]
    public var createdAt: Date?
    /// Bei YouTube die Kanalkennung aus `additionalData.channelId`.
    public var channelID: String?

    public init(
        platform: String? = nil, videoID: String? = nil, title: String? = nil, description: String? = nil,
        authorName: String? = nil, authorUsername: String? = nil, authorAvatarURL: URL? = nil,
        url: URL? = nil, duration: MediaDuration? = nil,
        thumbnailURL: URL? = nil, tags: [String] = [], createdAt: Date? = nil, channelID: String? = nil
    ) {
        self.channelID = channelID
        self.platform = platform; self.videoID = videoID; self.title = title; self.description = description
        self.authorName = authorName; self.authorUsername = authorUsername
        self.authorAvatarURL = authorAvatarURL; self.url = url; self.duration = duration
        self.thumbnailURL = thumbnailURL; self.tags = tags; self.createdAt = createdAt
    }
}

// MARK: - Lesen

extension SupadataDecoding {

    private struct MetadataBody: Decodable {
        struct Author: Decodable {
            let username: String?
            let displayName: String?
            let avatarUrl: String?
        }
        struct Media: Decodable {
            let duration: Double?
            let thumbnailUrl: String?
        }
        let platform: String?
        let id: String?
        let url: String?
        let title: String?
        let description: String?
        let author: Author?
        let media: Media?
        /// Je Plattform verschieden. Was nicht passt, fällt weg, statt die
        /// ganze Antwort unlesbar zu machen.
        struct Additional: Decodable {
            let channelId: String?
            private enum Keys: String, CodingKey { case channelId }
            init(from decoder: Decoder) throws {
                let container = try? decoder.container(keyedBy: Keys.self)
                channelId = try? container?.decodeIfPresent(String.self, forKey: .channelId)
            }
        }
        let tags: [String]?
        let createdAt: String?
        let additionalData: Additional?
    }

    /// 200 von `GET /v1/metadata`.
    public static func metadata(from data: Data) throws(SupadataError) -> SupadataMetadata {
        guard let body = try? JSONDecoder().decode(MetadataBody.self, from: data) else { throw .decoding }
        let name = [body.author?.displayName, body.author?.username]
            .compactMap { SupadataText.plain($0, limit: 200) }.first
        let tags = (body.tags ?? []).compactMap { SupadataText.plain($0, limit: 60) }
        return SupadataMetadata(
            platform: body.platform,
            videoID: body.id,
            title: SupadataText.plain(body.title, limit: 500),
            description: SupadataText.plain(body.description, limit: 20_000),
            authorName: name,
            authorUsername: SupadataText.plain(body.author?.username, limit: 100),
            authorAvatarURL: SupadataText.secureURL(body.author?.avatarUrl),
            url: SupadataText.secureURL(body.url),
            duration: body.media?.duration.flatMap { $0.isFinite && $0 > 0 ? MediaDuration(seconds: $0) : nil },
            thumbnailURL: SupadataText.secureURL(body.media?.thumbnailUrl),
            tags: Array(tags.prefix(30)),
            createdAt: body.createdAt.flatMap(SupadataText.date),
            channelID: body.additionalData?.channelId.flatMap { SourceResolver.isValidChannelID($0) ? $0 : nil })
    }
}

/// Fremden Text so annehmen, dass er nur Text ist.
enum SupadataText {

    /// Ohne Steuerzeichen, getrimmt, gedeckelt. Leer wird `nil`.
    static func plain(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let cleaned = String(raw.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    /// Nur https und nur Adressen, die die App auch sonst abrufen würde.
    static func secureURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              NetworkDestination.isAllowed(url) else { return nil }
        return url
    }

    static func date(_ raw: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(raw) { return date }
        return try? Date.ISO8601FormatStyle().parse(raw)
    }
}

// MARK: - Client

extension SupadataTranscriptClient {

    /// Die Metadaten einer Adresse. Einmal geholt, bleiben sie für die
    /// Sitzung im Speicher; die App hält sie darüber hinaus auf der Platte.
    public func metadata(for url: URL, apiKey: String) async throws(SupadataError) -> SupadataMetadata {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw .missingKey }
        if let cached = cachedMetadata(for: url) { return cached }
        guard var components = URLComponents(url: configuration.baseURL.appending(path: "metadata"),
                                             resolvingAgainstBaseURL: false) else { throw .invalidRequest }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let request = components.url else { throw .invalidRequest }
        let response = try await sendRequest(request, apiKey: key)
        guard response.status == 200 else {
            throw SupadataDecoding.error(status: response.status, body: response.body, retryAfter: response.retryAfter)
        }
        let metadata = try SupadataDecoding.metadata(from: response.body)
        rememberMetadata(metadata, for: url)
        return metadata
    }
}

// MARK: - Lücken füllen

public enum SupadataEnrichment {

    /// Plattformen, deren Links Supadata beschreibt.
    public static let supportedHosts: Set<String> = [
        "youtube.com", "youtu.be", "tiktok.com", "instagram.com", "x.com", "twitter.com", "facebook.com",
    ]

    /// Kann Supadata zu dieser Adresse etwas sagen?
    public static func supports(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return supportedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Fehlt der Folge etwas, das die Metadaten füllen könnten?
    public static func wantsMetadata(_ episode: Episode) -> Bool {
        guard supports(episode.webPageURL) else { return false }
        return episode.declaredDuration == nil
            || (episode.summary?.isEmpty ?? true)
            || looksTruncated(episode.summary)
            || episode.artworkURL == nil
    }

    /// Endet der Text mit „…“ oder „...“? So kürzen Feeds.
    public static func looksTruncated(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return text.hasSuffix("…") || text.hasSuffix("...")
    }

    /// Die Folge mit gefüllten Lücken. Titel, Adressen, Ton und alles, was
    /// der Feed schon sagt, bleiben unverändert.
    public static func enrich(_ episode: Episode, with metadata: SupadataMetadata) -> Episode {
        var result = episode
        if let full = metadata.description, completes(episode.summary, with: full) {
            result.summary = full
        }
        if result.declaredDuration == nil, let duration = metadata.duration { result.declaredDuration = duration }
        if result.publishedAt == nil, let date = metadata.createdAt { result.publishedAt = date }
        if result.artworkURL == nil, let thumbnail = metadata.thumbnailURL { result.artworkURL = thumbnail }
        if result.publisherChapters.isEmpty, let text = result.summary {
            let chapters = DescriptionChapters.parse(text, duration: result.declaredDuration)
            if !chapters.isEmpty { result.publisherChapters = chapters }
        }
        return result
    }

    /// Füllt beim Kanal Anbieter und Bild, wenn der Feed sie nicht nennt.
    public static func enrich(_ source: Source, with metadata: SupadataMetadata) -> Source {
        var result = source
        if (result.author?.isEmpty ?? true), let name = metadata.authorName { result.author = name }
        if result.artworkURL == nil, let avatar = metadata.authorAvatarURL { result.artworkURL = avatar }
        return result
    }

    /// Ersetzt die volle Beschreibung die vorhandene? Nur, wenn es keine gibt
    /// oder die vorhandene ein Anfang der vollen ist, gekürzt vom Feed.
    static func completes(_ existing: String?, with full: String) -> Bool {
        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty else {
            return true
        }
        guard full.count > existing.count else { return false }
        var stem = existing
        for suffix in ["…", "..."] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
        let normalize = { (text: String) in
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let prefix = normalize(stem)
        guard prefix.count >= 20 else { return false }
        return normalize(full).hasPrefix(prefix)
    }
}

// MARK: - Kapitel aus einer Beschreibung

/// Zeitmarken wie „00:00 Intro“ in einer Videobeschreibung als Kapitel.
///
/// Hinweis für das Zusammenführen: Ein anderer Zweig bringt einen eigenen
/// Parser für solche Kapitel (`TimestampChapters`). Gibt es ihn, soll diese
/// Hilfe darin aufgehen.
public enum DescriptionChapters {

    /// Kapitel nach der Regel von YouTube: mindestens drei, das erste bei
    /// 0:00, aufsteigend. Sonst keine, denn eine einzelne Zeitmarke in einer
    /// Beschreibung ist meist ein Verweis und keine Gliederung.
    public static func parse(_ text: String, duration: MediaDuration? = nil) -> [Chapter] {
        var chapters: [Chapter] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (time, title) = timestampedLine(String(line)) else { continue }
            if let duration, time.milliseconds > duration.milliseconds { continue }
            if let last = chapters.last, time <= last.start { continue }
            chapters.append(Chapter(start: time, title: title, provenance: .metadata))
        }
        guard chapters.count >= 3, chapters.first?.start == .zero else { return [] }
        return chapters
    }

    /// „00:00 Intro“, „1:02:03 - Teil zwei“, „(12:30) Fragen“.
    static func timestampedLine(_ line: String) -> (MediaTime, String)? {
        let pattern = #/^\s*[\(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?\s*[-–—:|·•]?\s*(.+?)\s*$/#
        guard let match = line.firstMatch(of: pattern) else { return nil }
        let parts = match.1.split(separator: ":").compactMap { Int64($0) }
        guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = parts.reduce(Int64(0)) { $0 * 60 + $1 }
        let title = String(match.2).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count <= 200 else { return nil }
        return (MediaTime(milliseconds: seconds * 1000), title)
    }
}
