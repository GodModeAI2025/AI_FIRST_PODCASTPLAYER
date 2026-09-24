//
//  AudioTwinCaptions.swift
//  PodcastAISources
//
//  Untertitel für eine Audiofolge aus ihrem Zwilling auf YouTube.
//
//  Viele Podcasts stehen auch als Video auf YouTube, oft mit Untertiteln.
//  Mit einem eigenen Supadata-Schlüssel spart das den Download und die
//  Spracherkennung der ganzen Folge. Die Reihenfolge für eine Folge mit Ton:
//
//  1. Das Transkript des Podcasts selbst (`podcast:transcript`).
//  2. Die Untertitel desselben Inhalts auf YouTube, über Supadata. Gesucht
//     wird zuerst in abonnierten Kanälen, die zu diesem Podcast gehören,
//     sonst mit einer Suche je Folge und Woche. Nur vorhandene Untertitel
//     (`mode=native`), nie eine Transkription durch Supadata.
//  3. Download und Spracherkennung auf dem Gerät, wie bisher.
//
//  Ohne Schlüssel gibt es Schritt 2 nicht, und nichts ändert sich.
//
//  Die Zeiten der Untertitel gelten für das Video. Ob und wie sie auf die
//  Audiodatei passen, prüft `CaptionAlignment` (PodcastAITranscription),
//  bevor etwas gespeichert wird. Hier steht nur, welcher Zwilling es ist.
//
//  Reine Logik ohne Netz, bis auf die eine Anfrage in `searchVideos`.
//

import Foundation
import PodcastAICore

// MARK: - Suche nach Videos

/// Ein Video aus der YouTube-Suche über Supadata.
public struct SupadataVideoResult: Hashable, Sendable {
    public let id: String
    public let title: String
    public let duration: MediaDuration?
    public let uploadDate: Date?
    public let channelID: String?
    public let channelName: String?

    public init(id: String, title: String, duration: MediaDuration? = nil, uploadDate: Date? = nil,
                channelID: String? = nil, channelName: String? = nil) {
        self.id = id; self.title = title; self.duration = duration; self.uploadDate = uploadDate
        self.channelID = channelID; self.channelName = channelName
    }

    public var watchURL: URL? { SourceResolver.watchURL(videoID: id) }
}

extension SupadataDecoding {

    private struct VideoSearchBody: Decodable {
        struct Channel: Decodable {
            let id: String?
            let name: String?
        }
        struct Result: Decodable {
            let type: String?
            let id: String?
            let title: String?
            let duration: Double?
            let uploadDate: String?
            let channel: Channel?
        }
        let results: [Result]?
    }

    /// Antwort von `GET /v1/youtube/search?type=video`. Nur Videos mit
    /// gültiger Kennung und Titel; was fehlt oder nicht passt, fällt weg.
    public static func videos(from data: Data) throws(SupadataError) -> [SupadataVideoResult] {
        guard let body = try? JSONDecoder().decode(VideoSearchBody.self, from: data) else { throw .decoding }
        return (body.results ?? []).compactMap { result in
            guard result.type == nil || result.type == "video",
                  let id = result.id, SourceResolver.isValidVideoID(id),
                  let title = SupadataText.plain(result.title, limit: 500) else { return nil }
            let duration = result.duration.flatMap { $0.isFinite && $0 > 0 ? MediaDuration(seconds: $0) : nil }
            let channelID = result.channel?.id.flatMap { SourceResolver.isValidChannelID($0) ? $0 : nil }
            return SupadataVideoResult(
                id: id, title: title, duration: duration,
                uploadDate: result.uploadDate.flatMap(SupadataText.date),
                channelID: channelID, channelName: SupadataText.plain(result.channel?.name, limit: 200))
        }
    }
}

extension SupadataTranscriptClient {

    /// Sucht Videos. Ohne `limit`, denn damit blättert Supadata selbst
    /// weiter und jede Seite kostet. So ist es eine Seite, ein Abruf.
    public func searchVideos(_ query: String, apiKey: String) async throws(SupadataError) -> [SupadataVideoResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let data = try await get(path: ["youtube", "search"], query: [
            URLQueryItem(name: "query", value: String(term.prefix(200))),
            URLQueryItem(name: "type", value: "video"),
        ], apiKey: apiKey)
        return try SupadataDecoding.videos(from: data)
    }
}

// MARK: - Den Zwilling erkennen

public enum AudioTwinMatcher {

    /// Höchstens so weit auseinander erschienen.
    public static let maxDateDistance: TimeInterval = 3 * 24 * 3600
    /// Höchstens so weit weichen die Längen voneinander ab, gemessen an der Folge.
    public static let durationTolerance = 0.10

    /// Die Suchanfrage: Podcast und Folge. Steht der Podcast schon im
    /// Titel der Folge, nur einmal.
    public static func searchQuery(podcastTitle: String, episodeTitle: String) -> String {
        let show = podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let episode = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = episode.localizedCaseInsensitiveContains(show) || show.isEmpty ? episode : show + " " + episode
        return String(query.prefix(200))
    }

    /// Das Video eines abonnierten Kanals, das dieselbe Folge ist.
    ///
    /// Fast derselbe Titel (ohne den Namen von Podcast und Kanal), höchstens
    /// drei Tage Abstand, und bei bekannter Länge höchstens zehn Prozent
    /// Unterschied. Ohne Datum muss der Titel genau passen.
    public static func fromChannel(episode: Episode, videos: [Episode], ignoring names: [String]) -> Episode? {
        let ignored = names.reduce(into: Set<String>()) { $0.formUnion(CounterpartEpisodeMatcher.words($1)) }
        var best: (video: Episode, score: Double)?
        for video in videos where video.id != episode.id {
            let score = titleScore(episode.title, video.title, ignoring: ignored)
            if let published = episode.publishedAt, let uploaded = video.publishedAt {
                guard abs(published.timeIntervalSince(uploaded)) <= maxDateDistance, score >= 0.6 else { continue }
            } else {
                guard score >= 0.999 else { continue }
            }
            guard durationFits(episode.declaredDuration, video.declaredDuration) != false else { continue }
            if best == nil || score > best!.score { best = (video, score) }
        }
        return best?.video
    }

    /// Das Suchergebnis, das dieselbe Folge ist, oder `nil`.
    ///
    /// Strenger als bei abonnierten Kanälen, denn eine Suche findet auch
    /// Ausschnitte, Reaktionen und Kopien. Ein Kanal gilt als vertraut, wenn
    /// er schon einmal den Zwilling lieferte oder so heißt wie der Podcast
    /// oder sein Autor. Dann reichen ein ähnlicher Titel und ein passendes
    /// Datum. Sonst müssen Titel, Datum und Länge alle stimmen. Liegen zwei
    /// fremde Ergebnisse gleichauf, keines.
    public static func fromSearch(
        episode: Episode, podcastTitle: String, podcastAuthor: String?,
        results: [SupadataVideoResult], preferredChannelID: String?
    ) -> SupadataVideoResult? {
        var accepted: [(result: SupadataVideoResult, score: Double, trusted: Bool)] = []
        for result in results {
            let trusted = (preferredChannelID != nil && result.channelID == preferredChannelID)
                || channelMatches(result.channelName, podcastTitle: podcastTitle, author: podcastAuthor)
            let ignored = CounterpartEpisodeMatcher.words(podcastTitle)
                .union(CounterpartEpisodeMatcher.words(result.channelName ?? ""))
            let score = titleScore(episode.title, result.title, ignoring: ignored)
            let dateFits: Bool? = if let published = episode.publishedAt, let uploaded = result.uploadDate {
                abs(published.timeIntervalSince(uploaded)) <= maxDateDistance
            } else {
                nil
            }
            let lengthFits = durationFits(episode.declaredDuration, result.duration)
            guard dateFits != false, lengthFits != false else { continue }
            if trusted {
                guard score >= 0.7, dateFits == true || score >= 0.95 else { continue }
            } else {
                guard score >= 0.85, dateFits == true, lengthFits == true else { continue }
            }
            accepted.append((result, score, trusted))
        }
        accepted.sort { ($0.trusted ? 1 : 0, $0.score) > ($1.trusted ? 1 : 0, $1.score) }
        guard let best = accepted.first else { return nil }
        if !best.trusted, accepted.count > 1, accepted[1].result.id != best.result.id,
           best.score - accepted[1].score < 0.02 {
            return nil
        }
        return best.result
    }

    /// Passen die Längen? `nil`, wenn eine fehlt.
    public static func durationFits(_ audio: MediaDuration?, _ video: MediaDuration?) -> Bool? {
        guard let audio, let video, audio.milliseconds > 0 else { return nil }
        let difference = abs(audio.milliseconds - video.milliseconds)
        return Double(difference) <= durationTolerance * Double(audio.milliseconds)
    }

    /// Titelähnlichkeit ohne die Wörter aus dem Namen von Podcast und Kanal.
    /// Bleibt davon zu wenig übrig, zählt der ganze Titel.
    static func titleScore(_ lhs: String, _ rhs: String, ignoring ignored: Set<String>) -> Double {
        func core(_ title: String) -> Set<String> {
            let all = CounterpartEpisodeMatcher.words(title)
            let rest = all.subtracting(ignored)
            return rest.count >= 2 ? rest : all
        }
        return CounterpartEpisodeMatcher.similarity(core(lhs), core(rhs))
    }

    /// Heißt der Kanal wie der Podcast oder sein Autor?
    static func channelMatches(_ channel: String?, podcastTitle: String, author: String?) -> Bool {
        let channelWords = CounterpartEpisodeMatcher.words(channel ?? "")
        guard !channelWords.isEmpty else { return false }
        for name in [podcastTitle, author ?? ""] {
            let nameWords = CounterpartEpisodeMatcher.words(name)
            guard !nameWords.isEmpty else { continue }
            if channelWords.isSubset(of: nameWords) || nameWords.isSubset(of: channelWords) { return true }
            if CounterpartEpisodeMatcher.similarity(channelWords, nameWords) >= 0.6 { return true }
        }
        return false
    }
}

// MARK: - Was die App sich merkt

/// Was die App je Folge über ihren Zwilling weiß, auf diesem Gerät.
public struct AudioTwinRecord: Codable, Equatable, Sendable {
    /// Wann zuletzt gesucht wurde. Höchstens einmal je Woche und Folge.
    public var searchedAt: Date?
    /// Der gefundene Zwilling. Ein späterer Versuch braucht keine Suche mehr.
    public var videoID: String?
    public var channelID: String?
    /// Der letzte gescheiterte Versuch, gleich welcher Schritt.
    public var failure: CaptionFailure?

    public init(searchedAt: Date? = nil, videoID: String? = nil, channelID: String? = nil,
                failure: CaptionFailure? = nil) {
        self.searchedAt = searchedAt; self.videoID = videoID; self.channelID = channelID; self.failure = failure
    }
}

public enum AudioTwinPlanner {

    /// So lange sucht die App für dieselbe Folge nicht noch einmal.
    public static let searchCooldown: TimeInterval = 7 * 24 * 3600

    public enum Step: Equatable, Sendable {
        case publisherTranscript
        case twinCaptions(TwinSource)
        case localTranscription
    }

    /// Woher der Zwilling kommt.
    public enum TwinSource: Equatable, Sendable {
        /// Aus einem abonnierten Kanal, der zu diesem Podcast gehört. Kostet keine Suche.
        case subscribedChannel(videoID: String)
        /// Schon früher gefunden.
        case rememberedVideo(videoID: String)
        /// Eine Suche über Supadata.
        case search(query: String)
    }

    public struct Inputs: Sendable {
        public var hasPublisherTranscript: Bool
        /// Schlüssel da, nicht abgelehnt, Schalter an, Dienst nicht in Ruhe.
        public var supadataAllowed: Bool
        /// Darf die Folge jetzt ins Netz? Von selbst nur im WLAN, von Hand
        /// nicht ohne Zustimmung im Mobilfunk, ohne Netz nie.
        public var networkAllowed: Bool
        public var record: AudioTwinRecord?
        public var subscribedTwinVideoID: String?
        public var searchQuery: String?
        public var now: Date

        public init(
            hasPublisherTranscript: Bool = false, supadataAllowed: Bool, networkAllowed: Bool,
            record: AudioTwinRecord? = nil, subscribedTwinVideoID: String? = nil, searchQuery: String? = nil,
            now: Date = Date()
        ) {
            self.hasPublisherTranscript = hasPublisherTranscript; self.supadataAllowed = supadataAllowed
            self.networkAllowed = networkAllowed; self.record = record
            self.subscribedTwinVideoID = subscribedTwinVideoID; self.searchQuery = searchQuery; self.now = now
        }
    }

    /// Darf gesucht werden? Einmal je Woche und Folge, auch von Hand.
    public static func maySearch(_ record: AudioTwinRecord?, now: Date) -> Bool {
        guard let searched = record?.searchedAt else { return true }
        return now >= searched.addingTimeInterval(searchCooldown)
    }

    /// Woher der Zwilling kommen soll, oder `nil`, wenn Schritt 2 entfällt.
    public static func twinSource(_ inputs: Inputs) -> TwinSource? {
        guard inputs.supadataAllowed, inputs.networkAllowed else { return nil }
        let record = inputs.record
        // Ein neuer Zwilling aus einem abonnierten Kanal ist neue Auskunft:
        // er gilt auch nach einem Fehlversuch mit einem anderen Video.
        if let subscribed = inputs.subscribedTwinVideoID, subscribed != record?.videoID {
            return .subscribedChannel(videoID: subscribed)
        }
        if let failure = record?.failure, inputs.now < failure.retryAt { return nil }
        if let subscribed = inputs.subscribedTwinVideoID { return .subscribedChannel(videoID: subscribed) }
        if let remembered = record?.videoID { return .rememberedVideo(videoID: remembered) }
        if let query = inputs.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
           maySearch(record, now: inputs.now) {
            return .search(query: query)
        }
        return nil
    }

    /// Die Schritte für eine Folge mit Ton, in dieser Reihenfolge. Der
    /// letzte ist immer die eigene Spracherkennung.
    public static func steps(_ inputs: Inputs) -> [Step] {
        var steps: [Step] = []
        if inputs.hasPublisherTranscript { steps.append(.publisherTranscript) }
        if let source = twinSource(inputs) { steps.append(.twinCaptions(source)) }
        steps.append(.localTranscription)
        return steps
    }
}
