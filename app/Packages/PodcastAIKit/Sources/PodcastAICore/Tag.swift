//
//  Tag.swift
//  PodcastAICore
//
//  Seit 0.10 sind Interessen Tags. Gespeichert wird weiter `StoredInterest`,
//  kein Feld heißt anders. `Tag` ist die Sicht darauf, die Tag-Wolke,
//  Klassifizierung und Trends brauchen.
//
//  Ein Tag trägt einen Schlüssel (`normalizedKey`). Unter ihm fallen
//  Schreibweisen zusammen: „USA“, „Vereinigte Staaten“ und „United States“
//  sind ein Tag. Den Schlüssel rechnet `TagNormalizer` in PodcastAIKnowledge
//  aus, denn dafür braucht es NaturalLanguage.
//

import Foundation

/// Wie jemand zu einem Tag steht. Plus heißt folgen, Minus heißt nicht mehr
/// folgen. Ein eigenes „stumm“ gibt es nicht: Ein Tag ohne Plus bleibt
/// sichtbar und neutral, es wird nur nicht mehr gesammelt.
public enum TagStance: String, Codable, Sendable, CaseIterable {
    case follow
    case neutral
}

/// Ein Tag, wie Wolke, Klassifizierung und Trends es sehen.
public struct Tag: Hashable, Codable, Sendable, Identifiable {
    public let id: InterestID
    public var label: String
    public var normalizedKey: String
    public var stance: TagStance
    public var origin: InterestOrigin
    /// Weitere Schreibweisen. Gespeichert in `StoredInterest.keywords`.
    public var aliases: [String]
    public var firstSeenAt: Date?

    public init(
        id: InterestID, label: String, normalizedKey: String, stance: TagStance,
        origin: InterestOrigin, aliases: [String] = [], firstSeenAt: Date? = nil
    ) {
        self.id = id; self.label = label; self.normalizedKey = normalizedKey
        self.stance = stance; self.origin = origin; self.aliases = aliases
        self.firstSeenAt = firstSeenAt
    }

    public init(_ interest: Interest) {
        self.init(
            id: interest.id, label: interest.label, normalizedKey: interest.normalizedKey,
            stance: interest.stance, origin: interest.origin, aliases: interest.keywords,
            firstSeenAt: interest.firstSeenAt)
    }

    public var isFollowed: Bool { stance == .follow && origin != .suggestedBySystem }

    /// In so vielen verschiedenen Quellen muss ein erkanntes Tag vorkommen,
    /// bevor die Wolke es zeigt. Ein Wort aus einem einzigen Podcast ist
    /// eher dessen Eigenheit als ein Thema.
    public static let detectedVisibilitySources = 2

    /// Zeigt die Wolke dieses Tag? Eigene Tags immer, erkannte erst ab
    /// ``detectedVisibilitySources`` Quellen oder wenn jemand Plus gewählt hat.
    /// `sourceCount` zählt die Quellen mit Kapiteln unter diesem Tag.
    public func isVisibleInCloud(sourceCount: Int) -> Bool {
        guard origin == .detected, stance != .follow else { return origin != .suggestedBySystem }
        return sourceCount >= Self.detectedVisibilitySources
    }

    /// Die Kennung für ein Tag, das die App selbst anlegt. Aus dem Schlüssel
    /// gerechnet, damit zwei Geräte, die dasselbe Tag gleichzeitig erkennen,
    /// dieselbe Zeile anlegen. Bestehende Interessen behalten ihre Kennung.
    public static func stableID(forKey normalizedKey: String) -> InterestID {
        InterestID(stable: "tag|" + normalizedKey)
    }
}

/// Ein Tag an einem Kapitel einer Folge.
///
/// Die Kennung ist aus Medienfassung, Kapitelstart und Tag-Schlüssel
/// gerechnet. Klassifizieren zwei Geräte dasselbe Kapitel, entsteht dieselbe
/// Kennung, und das Bereinigen nach dem Abgleich legt die Zeilen zusammen.
public struct ChapterTag: Hashable, Codable, Sendable, Identifiable {
    public let id: ChapterTagID
    public let episodeID: EpisodeID
    public let mediaVersionID: MediaVersionID
    public let chapterStartMs: Int
    public let chapterEndMs: Int
    public let interestID: InterestID
    public let normalizedKey: String
    /// Zwischen 0 und 1. Wie sicher die Zuordnung ist.
    public let confidence: Double
    /// War das Tag schon bekannt, als das Kapitel eingeordnet wurde?
    public let matchedKnown: Bool
    public let sourceID: SourceID
    /// Erscheinungsdatum der Folge. Danach zählen die Trends.
    public let publishedAt: Date?
    public let createdAt: Date
    public let transcriptRevision: Revision

    public init(
        episodeID: EpisodeID, mediaVersionID: MediaVersionID,
        chapterStartMs: Int, chapterEndMs: Int,
        interestID: InterestID, normalizedKey: String,
        confidence: Double, matchedKnown: Bool, sourceID: SourceID,
        publishedAt: Date?, createdAt: Date = Date(), transcriptRevision: Revision
    ) {
        self.id = Self.identifier(
            mediaVersionID: mediaVersionID, chapterStartMs: chapterStartMs, normalizedKey: normalizedKey)
        self.episodeID = episodeID; self.mediaVersionID = mediaVersionID
        self.chapterStartMs = chapterStartMs; self.chapterEndMs = chapterEndMs
        self.interestID = interestID; self.normalizedKey = normalizedKey
        self.confidence = min(max(confidence, 0), 1); self.matchedKnown = matchedKnown
        self.sourceID = sourceID; self.publishedAt = publishedAt
        self.createdAt = createdAt; self.transcriptRevision = transcriptRevision
    }

    /// Die Kennung eines Kapitel-Tags. Auf jedem Gerät dieselbe.
    public static func identifier(
        mediaVersionID: MediaVersionID, chapterStartMs: Int, normalizedKey: String
    ) -> ChapterTagID {
        ChapterTagID(stable: "chaptertag|\(mediaVersionID.rawValue)|\(chapterStartMs)|\(normalizedKey)")
    }

    public var chapterRange: MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: Int64(chapterStartMs)),
                       end: MediaTime(milliseconds: Int64(max(chapterEndMs, chapterStartMs))))
    }
}

/// Wie viele Kapitel einer Quelle ein Tag in einem Zeitraum trägt.
/// Grundlage für „Angesagt“ und „Neu“.
public struct ChapterTagCount: Hashable, Sendable {
    public let normalizedKey: String
    public let sourceID: SourceID
    public let chapterCount: Int

    public init(normalizedKey: String, sourceID: SourceID, chapterCount: Int) {
        self.normalizedKey = normalizedKey; self.sourceID = sourceID; self.chapterCount = chapterCount
    }
}
