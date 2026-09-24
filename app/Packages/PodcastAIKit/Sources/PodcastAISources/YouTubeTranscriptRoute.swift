//
//  YouTubeTranscriptRoute.swift
//  PodcastAISources
//
//  Woher eine YouTube-Folge ihr Transkript bekommt.
//
//  Die Reihenfolge steht hier und nicht verstreut in der Oberfläche:
//
//  1. Untertitel über Supadata, wenn ein eigener Schlüssel eingetragen ist,
//     der Schalter an ist und nichts dagegen spricht.
//  2. Sonst die passende Folge aus dem Audio-Podcast desselben Kanals, falls
//     er abonniert ist. Deren Ton transkribiert die App wie immer auf dem Gerät.
//  3. Sonst bleibt es bei Titel, Beschreibung und Kapiteln, mit einem
//     ruhigen Hinweis statt einer Fehlermeldung.
//
//  Alles hier ist reine Logik ohne Netz, damit sie sich prüfen lässt.
//

import Foundation
import PodcastAICore

// MARK: - YouTube-Adressen

public enum YouTubeLinks {

    /// Die Kennung des Videos hinter einer Folge, sofern die Adresse eines ist.
    public static func videoID(in url: URL?) -> String? {
        guard let url, case .youTubeVideo(let id, _, _)? = try? SourceResolver().resolve(url.absoluteString) else {
            return nil
        }
        return id
    }

    /// Die Adresse zum Ansehen, ohne Anhängsel wie `?si=` oder Zeitmarken.
    /// An ihr hängt die Medienfassung eines YouTube-Transkripts.
    public static func canonicalWatchURL(for url: URL?) -> URL? {
        videoID(in: url).flatMap(SourceResolver.watchURL(videoID:))
    }

    /// Öffnet das Video an einer Stelle: `watch?v=…&t=123s`. Ganze Sekunden,
    /// abgerundet, damit der Satz nicht schon begonnen hat.
    public static func watchURL(videoID: String, at time: MediaTime?) -> URL? {
        guard SourceResolver.isValidVideoID(videoID),
              var components = URLComponents(string: "https://www.youtube.com/watch") else { return nil }
        var items = [URLQueryItem(name: "v", value: videoID)]
        if let time, time.milliseconds >= 1000 {
            items.append(URLQueryItem(name: "t", value: "\(time.milliseconds / 1000)s"))
        }
        components.queryItems = items
        return components.url
    }
}

// MARK: - Entscheidung

/// Warum eine YouTube-Folge gerade kein Transkript bekommt.
public enum YouTubeTranscriptGap: Equatable, Sendable {
    /// Kein eigener Supadata-Schlüssel eingetragen.
    case noKey
    /// Supadata hat den Schlüssel abgelehnt. Aus, bis ein neuer kommt.
    case keyRejected
    /// Der Schalter in den Einstellungen ist aus.
    case switchedOff
    /// Kontingent aufgebraucht oder Supadata drosselt, der Dienst ruht eine Weile.
    case serviceResting
    /// Dieses Video hat keine Untertitel oder Supadata findet es nicht.
    case noCaptions
    /// Der letzte Versuch ist kurz her und scheiterte. Später wieder.
    case coolingDown(until: Date)
}

public enum YouTubeTranscriptRoute: Equatable, Sendable {
    /// Untertitel über Supadata holen.
    case captions
    /// Die passende Folge des abonnierten Audio-Podcasts transkribieren.
    case counterpartEpisode(EpisodeID, gap: YouTubeTranscriptGap)
    /// Zum Kanal gibt es einen Audio-Podcast, er ist aber nicht abonniert.
    case offerCounterpartPodcast(gap: YouTubeTranscriptGap)
    /// Nur Titel, Beschreibung und Kapitel.
    case metadataOnly(gap: YouTubeTranscriptGap)
}

/// Ein gescheiterter Versuch, gemerkt je Folge auf diesem Gerät.
public struct CaptionFailure: Equatable, Sendable, Codable {

    public enum Kind: String, Codable, Sendable {
        /// Keine Untertitel, Video weg, nicht erlaubt: kommt so wieder.
        case lasting
        /// Netz, Last, Frist: ein späterer Versuch kann gelingen.
        case passing
    }

    public let kind: Kind
    public let at: Date

    public init(kind: Kind, at: Date) {
        self.kind = kind
        self.at = at
    }

    public init(error: SupadataError, at: Date) {
        self.init(kind: error.isTransient ? .passing : .lasting, at: at)
    }

    /// Nach einem bleibenden Fehler fragt die App eine Woche nicht mehr von
    /// selbst, nach einem vorübergehenden sechs Stunden. Später hat das
    /// Video vielleicht Untertitel bekommen.
    public static let lastingCooldown: TimeInterval = 7 * 24 * 3600
    public static let passingCooldown: TimeInterval = 6 * 3600

    public var retryAt: Date {
        at.addingTimeInterval(kind == .lasting ? Self.lastingCooldown : Self.passingCooldown)
    }
}

public enum YouTubeTranscriptPlanner {

    public struct Inputs: Sendable {
        public var switchedOn: Bool
        public var hasKey: Bool
        public var keyRejected: Bool
        public var serviceResting: Bool
        /// Der letzte gescheiterte Versuch für dieses Video, falls es einen gab.
        public var lastFailure: CaptionFailure?
        /// Von Hand angefordert: die Wartezeit nach einem Fehler gilt dann nicht.
        public var requestedByHand: Bool
        /// Die passende Folge eines abonnierten Audio-Podcasts.
        public var matchingAudioEpisode: EpisodeID?
        /// Es gibt zum Kanal einen Audio-Podcast im Verzeichnis.
        public var hasCounterpartPodcast: Bool
        public var now: Date

        public init(
            switchedOn: Bool, hasKey: Bool, keyRejected: Bool = false, serviceResting: Bool = false,
            lastFailure: CaptionFailure? = nil, requestedByHand: Bool = false,
            matchingAudioEpisode: EpisodeID? = nil, hasCounterpartPodcast: Bool = false,
            now: Date = Date()
        ) {
            self.switchedOn = switchedOn; self.hasKey = hasKey; self.keyRejected = keyRejected
            self.serviceResting = serviceResting; self.lastFailure = lastFailure
            self.requestedByHand = requestedByHand; self.matchingAudioEpisode = matchingAudioEpisode
            self.hasCounterpartPodcast = hasCounterpartPodcast; self.now = now
        }
    }

    /// Warum Supadata gerade nicht gefragt wird, oder `nil`, wenn es geht.
    public static func captionGap(_ inputs: Inputs) -> YouTubeTranscriptGap? {
        if !inputs.hasKey { return .noKey }
        if inputs.keyRejected { return .keyRejected }
        if !inputs.switchedOn { return .switchedOff }
        if inputs.serviceResting { return .serviceResting }
        if let failure = inputs.lastFailure, !inputs.requestedByHand {
            if inputs.now < failure.retryAt {
                return failure.kind == .lasting ? .noCaptions : .coolingDown(until: failure.retryAt)
            }
        }
        return nil
    }

    public static func route(_ inputs: Inputs) -> YouTubeTranscriptRoute {
        guard let gap = captionGap(inputs) else { return .captions }
        if let episode = inputs.matchingAudioEpisode { return .counterpartEpisode(episode, gap: gap) }
        if inputs.hasCounterpartPodcast { return .offerCounterpartPodcast(gap: gap) }
        return .metadataOnly(gap: gap)
    }

    /// Nach einem Fehler von Supadata: wohin jetzt? Untertitel gibt es
    /// diesmal nicht, also greift der Rest der Reihenfolge.
    public static func fallback(after error: SupadataError, inputs: Inputs) -> YouTubeTranscriptRoute {
        let gap: YouTubeTranscriptGap = switch error {
        case .missingKey: .noKey
        case .unauthorized: .keyRejected
        case .quota, .rateLimited: .serviceResting
        case .notFound, .noTranscript, .forbidden, .invalidRequest: .noCaptions
        case .server, .network, .timeout, .jobFailed, .cancelled, .decoding:
            .coolingDown(until: CaptionFailure(error: error, at: inputs.now).retryAt)
        }
        if let episode = inputs.matchingAudioEpisode { return .counterpartEpisode(episode, gap: gap) }
        if inputs.hasCounterpartPodcast { return .offerCounterpartPodcast(gap: gap) }
        return .metadataOnly(gap: gap)
    }
}

// MARK: - Passende Folge im Audio-Podcast

public enum CounterpartEpisodeMatcher {

    /// Die Folge des Audio-Podcasts, die dasselbe ist wie das Video.
    ///
    /// Gleich heißt: fast derselbe Titel (Wörter ohne Satzzeichen, Groß- und
    /// Kleinschreibung egal) und erschienen im Abstand von höchstens drei
    /// Tagen. Fehlt ein Datum, muss der Titel genau passen. Im Zweifel
    /// keine Folge, denn eine falsche lieferte ein fremdes Transkript.
    public static func match(
        videoTitle: String, videoPublished: Date?, in candidates: [Episode],
        maxDistance: TimeInterval = 3 * 24 * 3600, threshold: Double = 0.6
    ) -> Episode? {
        let videoWords = words(videoTitle)
        guard !videoWords.isEmpty else { return nil }
        var best: (episode: Episode, score: Double)?
        for episode in candidates where episode.audioURL != nil {
            let score = similarity(videoWords, words(episode.title))
            let exact = score >= 0.999
            if let videoPublished, let published = episode.publishedAt {
                guard abs(published.timeIntervalSince(videoPublished)) <= maxDistance else { continue }
                guard score >= threshold else { continue }
            } else {
                guard exact else { continue }
            }
            if best == nil || score > best!.score { best = (episode, score) }
        }
        return best?.episode
    }

    static func words(_ title: String) -> Set<String> {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    /// Gemeinsame Wörter im Verhältnis zur Länge beider Titel (Dice).
    /// Ein Zusatz wie „(mit Gast)“ im Podcasttitel drückt den Wert nur wenig.
    static func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let total = lhs.count + rhs.count
        guard total > 0 else { return 0 }
        return 2 * Double(lhs.intersection(rhs).count) / Double(total)
    }
}
