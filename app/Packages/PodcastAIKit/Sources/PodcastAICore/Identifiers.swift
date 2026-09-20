//
//  Identifiers.swift
//  PodcastAICore
//
//  Getypte Identitäten. Eine Folge ist nicht ihre Medienfassung, und eine
//  Medienfassung ist nicht ihr Transkript. Diese Unterscheidung mit rohen
//  UUIDs auszudrücken ist eine Einladung zu genau den Verwechslungen, die
//  später als falscher Timecode beim Nutzer ankommen.
//

import Foundation

/// Stabile, typisierte Kennung. Der Phantomparameter verhindert, dass eine
/// `EpisodeID` dort eingesetzt wird, wo eine `MediaVersionID` erwartet wird.
public struct TypedID<Subject>: Hashable, Codable, Sendable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString }

    /// Ableitung aus einem stabilen natürlichen Schlüssel — etwa der Feed-GUID
    /// einer Folge. Zweimaliges Einlesen desselben Feeds erzeugt damit dieselbe
    /// Kennung statt eines Duplikats.
    public init(stable key: String) {
        self.rawValue = StableDigest.hex(of: key)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SourceSubject {}
public enum EpisodeSubject {}
public enum MediaVersionSubject {}
public enum TranscriptSubject {}
public enum SegmentSubject {}
public enum EvidenceSubject {}
public enum ClaimSubject {}
public enum HighlightSubject {}
public enum InterestSubject {}
public enum SmartFeedSubject {}
public enum PersonalEpisodeSubject {}
public enum PlaybackPlanSubject {}
public enum KnowledgeNodeSubject {}

public typealias SourceID = TypedID<SourceSubject>
public typealias EpisodeID = TypedID<EpisodeSubject>
public typealias MediaVersionID = TypedID<MediaVersionSubject>
public typealias TranscriptID = TypedID<TranscriptSubject>
public typealias SegmentID = TypedID<SegmentSubject>
public typealias EvidenceID = TypedID<EvidenceSubject>
public typealias ClaimID = TypedID<ClaimSubject>
public typealias HighlightID = TypedID<HighlightSubject>
public typealias InterestID = TypedID<InterestSubject>
public typealias SmartFeedID = TypedID<SmartFeedSubject>
public typealias PersonalEpisodeID = TypedID<PersonalEpisodeSubject>
public typealias PlaybackPlanID = TypedID<PlaybackPlanSubject>
public typealias KnowledgeNodeID = TypedID<KnowledgeNodeSubject>

/// Deterministischer Hash ohne CryptoKit, damit die Domäne plattformfrei bleibt.
///
/// Zweck ist **Identität und Deduplizierung**, nicht Sicherheit: gleicher
/// Eingabetext ergibt auf jedem Gerät und in jedem Prozesslauf dieselbe Kennung.
/// Für Integrität von Mediendateien wird stattdessen SHA-256 aus CryptoKit
/// verwendet (siehe `PodcastAIMedia`).
///
/// Bewusst nicht `Hashable.hashValue`: Swift würfelt den Seed pro Prozessstart,
/// damit wären Kennungen zwischen zwei Starts verschieden.
public enum StableDigest {

    /// Zwei FNV-1a-64-Durchläufe mit verschiedenen Offset-Basen, aneinandergehängt.
    /// Ergibt 32 Hexzeichen.
    public static func hex(of string: String) -> String {
        let bytes = Array(string.utf8)
        let a = fnv1a64(bytes, offsetBasis: 0xcbf2_9ce4_8422_2325)
        let b = fnv1a64(bytes, offsetBasis: 0x9dcf_9b0d_1e7a_3d41)
        return String(format: "%016llx%016llx", a, b)
    }

    private static func fnv1a64(_ bytes: [UInt8], offsetBasis: UInt64) -> UInt64 {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash = offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Reihenfolgeunabhängige Kennung über mehrere Bestandteile.
    /// Für Manifeste, deren Identität nicht von der Sortierung abhängen darf.
    public static func hex(ofUnordered parts: [String]) -> String {
        hex(of: parts.sorted().joined(separator: "\u{1F}"))
    }

    /// Reihenfolgeabhängige Kennung. Für Hörpläne, bei denen die Abfolge Teil
    /// der Identität ist.
    public static func hex(ofOrdered parts: [String]) -> String {
        hex(of: parts.joined(separator: "\u{1F}"))
    }
}
