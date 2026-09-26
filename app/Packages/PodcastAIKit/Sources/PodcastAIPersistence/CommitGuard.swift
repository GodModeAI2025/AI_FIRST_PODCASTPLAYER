//
//  CommitGuard.swift
//  PodcastAIPersistence
//
//  Der Wächter vor jedem Schreiben der Erschließung (docs/plan-pipeline.md,
//  Schritt 1).
//
//  Transkript, Belege, Fakten und Kapitel-Tags entstehen über Minuten. In
//  dieser Zeit kann die Folge gelöscht werden, ihre Quelle abbestellt, ein
//  anderes Gerät ein Merkzeichen schicken oder der Feed auf eine andere
//  Audiodatei zeigen. Bis 0.12 prüfte das Modell der App das vor dem
//  Schreiben, der Store schrieb danach, was kam. Zwischen Prüfen und
//  Schreiben lag ein `await`, und eine fehlende Zeile der Folge hielt die
//  Kapitel-Tags gar nicht auf.
//
//  Jetzt prüft der Store selbst, im selben Schritt seines ModelActors, in
//  dem er schreibt: Die Folge hat eine lebende Zeile, sie trägt kein
//  Merkzeichen, ihre Quelle besteht, das Löschprotokoll kennt keine
//  Löschung seit dem Start der Arbeit, und die Eingabe ist noch die, aus
//  der das Ergebnis entstand. Sonst schreibt er nichts und sagt warum.
//
//  Bei der Fassung eines Transkripts ist er nachsichtig: Zeigt der Feed auf
//  eine andere Datei, gilt das Ergebnis erst als überholt, wenn diese schon
//  ein Transkript hat. Manche Feeds ändern die Audioadresse bei jedem
//  Abruf, und ein Aktualisieren mitten im Transkript nähme sonst die ganze
//  Arbeit weg.
//
//  Geht das Schreiben durch, kommt ein Beleg über das Geschriebene zurück
//  (`WriteReceipt`). Wird die Folge gleich danach gelöscht, räumt die Arbeit
//  genau diese Zeilen wieder weg, auch bei YouTube-Folgen ohne Audioadresse.
//
//  Lokalen Ton verlangt der Wächter nie: „Audio entfernen“ leert nur den
//  Pfad der Datei, alle Daten der Folge bleiben gültig.
//

import Foundation
import PodcastAICore

/// Was ein Schreiben der Erschließung voraussetzt.
public struct CommitGuard: Sendable {

    /// Warum der Store nichts geschrieben hat.
    public enum StaleReason: String, Sendable, Equatable, CustomStringConvertible {
        /// Keine lebende Zeile der Folge, etwa nach dem Abbestellen ihrer
        /// Quelle hier oder auf einem anderen Gerät.
        case episodeMissing
        /// Die Folge trägt ein Merkzeichen.
        case episodeRemoved
        /// Die lebende Zeile hängt an keiner Quelle mehr.
        case sourceMissing
        /// Folge oder Quelle wurden gelöscht, nachdem die Arbeit begann.
        case removedWhileRunning
        /// Der Feed zeigt inzwischen auf eine andere Fassung, und für sie
        /// liegt schon ein Transkript.
        case mediaChanged
        /// Die Eingabe, aus der das Ergebnis entstand, gibt es nicht mehr.
        case inputChanged
        /// Es liegt schon ein Ergebnis aus einer neueren Eingabe vor.
        case superseded

        public var description: String { rawValue }

        /// Kommt der Grund von einer Löschung? Dann bleibt von der Folge
        /// nichts, auch nicht, was die Oberfläche schon zeigt.
        public var meansRemoved: Bool {
            switch self {
            case .episodeMissing, .episodeRemoved, .sourceMissing, .removedWhileRunning: true
            case .mediaChanged, .inputChanged, .superseded: false
            }
        }
    }

    /// Die Folge, für die geschrieben wird.
    public let episodeID: EpisodeID
    /// Der Stand des Löschprotokolls beim Start der Arbeit.
    public let ticket: RemovalLedger.Ticket
    public let ledger: RemovalLedger
    /// Auf welche Fassung der Feed jetzt zeigt, aus der frisch gelesenen
    /// Zeile der Folge: die Audioadresse, bei Videos die Adresse des Videos.
    /// Die Regel für Videos kennt erst `PodcastAIKit`, sie kommt deshalb von
    /// dort herein. Ohne Angabe gilt nur die Audioadresse.
    public let feedMedia: @Sendable (Episode) -> MediaVersionID?

    public init(
        episode: EpisodeID,
        since ticket: RemovalLedger.Ticket,
        ledger: RemovalLedger = .shared,
        feedMedia: @escaping @Sendable (Episode) -> MediaVersionID? = { CommitGuard.audioMedia(of: $0) }
    ) {
        self.episodeID = episode
        self.ticket = ticket
        self.ledger = ledger
        self.feedMedia = feedMedia
    }

    /// Die Fassung der Audiodatei aus dem Feed, dieselbe Regel wie beim Laden.
    public static func audioMedia(of episode: Episode) -> MediaVersionID? {
        episode.audioURL.map { MediaVersionID(stable: $0.absoluteString) }
    }
}

/// Was ein Schreiben angelegt hat. Nur neue Zeilen stehen darin: ein
/// Transkript, das schon da war, oder ein Beleg, den es schon gab, nicht.
public struct WriteReceipt: Sendable, Equatable {
    public let episodeID: EpisodeID
    /// Medienfassungen, deren Zeile dieses Schreiben angelegt hat.
    public internal(set) var mediaVersionIDs: [MediaVersionID] = []
    public internal(set) var transcriptIDs: [TranscriptID] = []
    public internal(set) var evidenceIDs: [EvidenceID] = []
    public internal(set) var factIDs: [String] = []
    public internal(set) var chapterTagIDs: [ChapterTagID] = []
    /// Erkannte Tags, die dieses Schreiben neu angelegt hat.
    public internal(set) var tagIDs: [InterestID] = []
    /// Lag für die Fassung schon ein Transkript, blieb es stehen, und die
    /// Belege entstanden aus ihm statt aus dem neuen.
    public internal(set) var keptTranscriptID: TranscriptID?

    public init(episodeID: EpisodeID) {
        self.episodeID = episodeID
    }

    /// Hat dieses Schreiben eine Zeile angelegt?
    public var isEmpty: Bool {
        mediaVersionIDs.isEmpty && transcriptIDs.isEmpty && evidenceIDs.isEmpty
            && factIDs.isEmpty && chapterTagIDs.isEmpty && tagIDs.isEmpty
    }

    /// Fasst die Belege mehrerer Schreibvorgänge derselben Arbeit zusammen,
    /// etwa die erkannten Tags einer Einordnung und ihre Kapitel-Tags.
    public mutating func merge(_ other: WriteReceipt) {
        func union<T: Hashable>(_ lhs: [T], _ rhs: [T]) -> [T] {
            var seen = Set(lhs)
            return lhs + rhs.filter { seen.insert($0).inserted }
        }
        mediaVersionIDs = union(mediaVersionIDs, other.mediaVersionIDs)
        transcriptIDs = union(transcriptIDs, other.transcriptIDs)
        evidenceIDs = union(evidenceIDs, other.evidenceIDs)
        factIDs = union(factIDs, other.factIDs)
        chapterTagIDs = union(chapterTagIDs, other.chapterTagIDs)
        tagIDs = union(tagIDs, other.tagIDs)
        keptTranscriptID = keptTranscriptID ?? other.keptTranscriptID
    }
}

/// Das Ergebnis eines geschützten Schreibens.
public enum CommitResult<Value: Sendable>: Sendable {
    case written(WriteReceipt, Value)
    case stale(CommitGuard.StaleReason)

    public var receipt: WriteReceipt? {
        if case .written(let receipt, _) = self { receipt } else { nil }
    }

    public var staleReason: CommitGuard.StaleReason? {
        if case .stale(let reason) = self { reason } else { nil }
    }

    /// Beleg und Wert, oder ``StaleWriteError``.
    public func get() throws -> (receipt: WriteReceipt, value: Value) {
        switch self {
        case .written(let receipt, let value): return (receipt, value)
        case .stale(let reason): throw StaleWriteError(reason: reason)
        }
    }
}

/// Der Store hat nichts geschrieben, weil der Wächter widersprach. Kein
/// Fehler für den Nutzer: Die Arbeit war überholt und endet still.
public struct StaleWriteError: Error, Sendable, Equatable {
    public let reason: CommitGuard.StaleReason

    public init(reason: CommitGuard.StaleReason) {
        self.reason = reason
    }
}
