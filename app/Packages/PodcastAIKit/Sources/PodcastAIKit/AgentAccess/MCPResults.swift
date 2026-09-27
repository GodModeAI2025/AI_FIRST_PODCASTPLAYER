//
//  MCPResults.swift
//  PodcastAIKit
//
//  Was ein Agent zu sehen bekommt.
//
//  Eigene Formen statt der Domänentypen: hier wird entschieden, was nach
//  draußen geht. Interne Kennungen von Medienfassung und Transkriptrevision
//  gehören nicht dazu. Der Agent braucht Podcast, Folge, Zeit und Text.
//
//  Jedes Ergebnis ist ein Objekt. MCP verlangt für `structuredContent` ein
//  JSON-Objekt; bis 0.13 kamen Listen zurück, und Claude Desktop, Claude
//  Code und das offizielle SDK verwarfen vier von fünf Antworten als
//  ungültig.
//

#if os(macOS)
import Foundation
import PodcastAICore

/// Eine Stelle aus einem Transkript.
public struct EvidenceSummary: Codable, Equatable, Sendable {

    public let id: String
    public let podcastID: String
    public let podcast: String?
    public let episode: String?
    public let publishedAt: Date?
    public let quotedText: String
    public let startSeconds: Double?
    public let endSeconds: Double?
    /// Die Startzeit zum Lesen, etwa „12:34“ oder „1:02:03“.
    public let timecode: String?
    public let speaker: String?

    init(_ evidence: Evidence, podcast: String? = nil, episode: String? = nil, publishedAt: Date? = nil) {
        self.id = evidence.id.rawValue
        self.podcastID = evidence.sourceID.rawValue
        self.podcast = podcast
        self.episode = episode
        self.publishedAt = publishedAt
        self.quotedText = evidence.quotedText
        self.startSeconds = evidence.range?.start.seconds
        self.endSeconds = evidence.range?.end.seconds
        self.timecode = evidence.range.map { MCPTimecode.string(seconds: $0.start.seconds) }
        self.speaker = evidence.attributedSpeaker
    }
}

/// Eine gemerkte Stelle.
public struct HighlightSummary: Codable, Equatable, Sendable {
    public let id: String
    public let note: String?
    public let capturedAt: Date
    public let podcast: String?
    public let episode: String?
    public let quotedText: String
    public let startSeconds: Double?
    public let timecode: String?
    /// Nur gesetzt, wenn `getEvidence` die Stelle findet. Aus dem Player
    /// Gemerktes trägt nur eine Kopie von Zitat und Zeitmarke.
    public let evidenceID: String?

    init(id: String, note: String?, capturedAt: Date, podcast: String?, episode: String?,
         quotedText: String, startSeconds: Double?, evidenceID: String?) {
        self.id = id
        self.note = note
        self.capturedAt = capturedAt
        self.podcast = podcast
        self.episode = episode
        self.quotedText = quotedText
        self.startSeconds = startSeconds
        self.timecode = startSeconds.map(MCPTimecode.string(seconds:))
        self.evidenceID = evidenceID
    }
}

/// Eine gesicherte Antwort aus dem Chat.
public struct TrailSummary: Codable, Equatable, Sendable {
    public let id: String
    public let question: String
    /// Fehlt, wenn eine zitierte Stelle nicht mehr da ist oder die Antwort
    /// keine Stellen nennt. Dann ließe sich nicht prüfen, woher sie stammt.
    public let answer: String?
    public let note: String?
    public let parkedAt: Date
    /// Die Stellen hinter der Antwort, für `getEvidence`.
    public let evidenceIDs: [String]
}

/// Ein freigegebener Podcast.
public struct PodcastSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let language: String?
    public let episodesWithTranscript: Int
}

public struct MCPPodcastList: Codable, Equatable, Sendable {
    public let podcasts: [PodcastSummary]
}

public struct MCPInterestList: Codable, Equatable, Sendable {
    public let interests: [String]
}

public struct MCPSearchResult: Codable, Equatable, Sendable {
    public let results: [EvidenceSummary]
    /// Ein Hinweis für den Agenten, wenn nichts gefunden wurde.
    public let hint: String?

    /// Für das Modell des Agenten geschrieben, das ihn oft an den Menschen
    /// weitergibt. Deshalb in der Sprache des Macs.
    static var noMatch: String {
        String(localized: """
            Keine passende Stelle. Versuche eine kürzere Frage oder andere Stichworte in der Sprache des \
            Podcasts. listPodcasts zeigt, welche Podcasts freigegeben sind und wie viele Folgen ein Transkript \
            haben.
            """, bundle: .module)
    }
    static var nothingTranscribed: String {
        String(localized: """
            In den freigegebenen Podcasts hat noch keine Folge ein Transkript. Transkripte entstehen in der \
            App PodcastAI, nicht über diesen Zugang.
            """, bundle: .module)
    }
    static var podcastEmpty: String {
        String(localized: """
            Zu dieser podcastID gibt es im freigegebenen Bereich keine Folge mit Transkript. listPodcasts \
            nennt die freigegebenen Podcasts mit ihrer Kennung.
            """, bundle: .module)
    }
}

public struct MCPHighlightList: Codable, Equatable, Sendable {
    public let highlights: [HighlightSummary]
}

public struct MCPTrailList: Codable, Equatable, Sendable {
    public let trails: [TrailSummary]
}

/// Zeitmarken wie im Player.
enum MCPTimecode {
    static func string(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
#endif
