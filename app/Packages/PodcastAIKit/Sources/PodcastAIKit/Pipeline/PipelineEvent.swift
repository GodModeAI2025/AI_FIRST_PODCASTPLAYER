//
//  PipelineEvent.swift
//  PodcastAIKit
//
//  Die Ereignisse der Verarbeitung als Stufen-Pipeline (docs/plan-pipeline.md).
//
//  Der Store ist die Wahrheit, ein Ereignis ist nur ein Hinweis. Geht eines
//  verloren oder kommt es doppelt, schadet das nicht: Jede Stufe prüft vor
//  dem Start im `LibraryStore`, ob ihr Ergebnis für diese Eingangsfassung
//  schon da ist, und `reconcile()` findet, was liegen blieb.
//
//  Gesendet wird erst, wenn das Schreiben im Store zurückgekehrt ist. Einzige
//  Ausnahme ist `episodesRemoved`: Der Abbruch soll beginnen, bevor der Store
//  gelöscht hat.
//

import Foundation
import PodcastAICore
import PodcastAIIntelligence
import PodcastAIPersistence

/// Wer eine Arbeit wollte. Die höhere gewinnt, wenn dieselbe Folge mehrfach
/// ansteht.
///
/// Den Wert setzt nur der Code an der Stelle, an der ein Mensch etwas
/// anfordert oder die App selbst etwas einreiht. Weder ein Feed noch
/// Supadata noch eine abgeglichene Zeile heben ihn an (Regel 2).
public enum Origin: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Das Archiv eines Podcasts oder der Rückstand der Bibliothek.
    case backlog
    /// Von selbst eingereiht, etwa eine neue Folge eines Abos.
    case automatic
    /// Von einem Menschen angefordert, per Tippen oder über Siri.
    case user

    // Enums mit Rohwert bekommen kein `<` geschenkt.
    public static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Die Fassung, aus der eine Stufe ihr Ergebnis rechnet: Medienfassung und
/// Fingerabdruck des Transkripts.
///
/// `Revision` allein taugt dafür nicht, sie ist beim Zusammensetzen eines
/// Transkripts immer `.initial`. Kennung, Zahl der Segmente und Ende des
/// letzten Segments unterscheiden zwei Transkripte derselben Fassung.
public struct InputVersion: Sendable, Hashable {
    public let mediaVersionID: MediaVersionID
    public let transcriptID: TranscriptID
    public let revision: Revision
    public let segmentCount: Int
    public let lastEndMs: Int

    public init(mediaVersionID: MediaVersionID, transcriptID: TranscriptID, revision: Revision,
                segmentCount: Int, lastEndMs: Int) {
        self.mediaVersionID = mediaVersionID
        self.transcriptID = transcriptID
        self.revision = revision
        self.segmentCount = segmentCount
        self.lastEndMs = lastEndMs
    }

    public init(mediaVersionID: MediaVersionID, fingerprint: LibraryStore.TranscriptFingerprint) {
        self.init(mediaVersionID: mediaVersionID, transcriptID: fingerprint.id, revision: fingerprint.revision,
                  segmentCount: fingerprint.segmentCount, lastEndMs: fingerprint.lastEndMs)
    }

    /// Der Fingerabdruck, wie ihn der Store liefert.
    public var fingerprint: LibraryStore.TranscriptFingerprint {
        LibraryStore.TranscriptFingerprint(
            id: transcriptID, revision: revision, segmentCount: segmentCount, lastEndMs: lastEndMs)
    }
}

/// Warum ein Transkript nicht entstand, grob genug für die Entscheidung der
/// Empfänger: noch einmal versuchen, nie wieder von selbst, oder die ganze
/// Sprache beziehungsweise das ganze Gerät aufgeben.
public struct TranscriptFailure: Sendable, Hashable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// Geht vorbei: Netz, Last, Zeit. Ein zweiter Versuch lohnt.
        case transient
        /// Käme bei jedem Versuch wieder, etwa ein unbekanntes Audioformat.
        case permanent
        /// Für die Sprache der Folge gibt es kein Modell.
        case localeNotSupported
        /// Das Gerät kann gar nicht transkribieren.
        case speechUnavailable
        /// Alles andere.
        case other
    }

    public let kind: Kind
    /// Der Satz, den die Folge zeigt. Nur zum Anzeigen, nie eine Anweisung.
    public let message: String?

    public init(_ kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }
}

/// Wodurch Folgen verschwinden.
public enum RemovalScope: Sendable, Hashable {
    /// „Folge löschen“ auf diesem Gerät.
    case episode
    /// „Quelle abbestellen“ auf diesem Gerät, samt allen Folgen.
    case source(SourceID)
    /// Gelöscht oder abbestellt auf einem anderen Gerät, angekommen über iCloud.
    case elsewhere
}

/// Was sich auf einem anderen Gerät geändert hat. Bis die Historie das
/// genauer sagt, gilt immer alles.
public enum ChangeSet: Sendable, Hashable {
    case all
}

/// Ein Hinweis zwischen den Stufen. Massenereignisse tragen Listen, damit
/// ein Aktualisieren mit hundert neuen Folgen ein Ereignis bleibt.
public enum PipelineEvent: Sendable, Equatable {
    /// Neue Folgen liegen im Store: nach dem Aktualisieren, einem Abo, einer
    /// einzelnen Folge oder „Neu laden“.
    case episodesAdded([EpisodeID], Origin)
    /// Der Ton einer Fassung liegt jetzt auf dem Gerät.
    case audioAvailable(EpisodeID, MediaVersionID)
    /// Der Ton dieser Folgen ist weg. Alle Daten bleiben (Regel 5).
    case audioRemoved([EpisodeID])
    /// Das Transkript ist gespeichert.
    case transcriptSaved(EpisodeID, InputVersion, Origin)
    /// Aus dem Transkript wurde nichts.
    case transcriptFailed(EpisodeID, TranscriptFailure, Origin)
    /// Transkript und Belege sind gespeichert. Ab hier können Fakten und
    /// Tags entstehen.
    case evidenceReady(EpisodeID, InputVersion, Origin)
    /// Die Warteschlange der Transkripte ist leer gelaufen.
    case transcriptsIdle
    /// Ein Lauf der Fakten ist zu Ende, wie auch immer.
    case factsDone(EpisodeID, InputVersion, FactsOutcome, Origin)
    /// Eine Einordnung der Kapitel ist zu Ende, wie auch immer.
    case tagsDone(EpisodeID, InputVersion, ChapterTagsOutcome, Origin)
    /// Die Feeds sind aktualisiert.
    case feedsRefreshed(byUser: Bool)
    /// Eine Ausgabe eines Themen-Updates ist erschienen, mit allen Teilen.
    case editionPublished(SmartFeedID, [PersonalEpisodeID])
    /// Diese Folgen verschwinden. Kommt, bevor der Store löscht.
    case episodesRemoved([EpisodeID], RemovalScope)
    /// Ein anderes Gerät hat etwas geändert.
    case changedElsewhere(ChangeSet)

    /// Die Art des Ereignisses ohne Inhalt. Danach richtet der Router die
    /// Wege aus, und danach fragt, wer ein Ereignis erst bauen muss.
    public enum Kind: Sendable, Hashable, CaseIterable {
        case episodesAdded, audioAvailable, audioRemoved, transcriptSaved, transcriptFailed
        case evidenceReady, transcriptsIdle, factsDone, tagsDone, feedsRefreshed
        case editionPublished, episodesRemoved, changedElsewhere
    }

    public var kind: Kind {
        switch self {
        case .episodesAdded: .episodesAdded
        case .audioAvailable: .audioAvailable
        case .audioRemoved: .audioRemoved
        case .transcriptSaved: .transcriptSaved
        case .transcriptFailed: .transcriptFailed
        case .evidenceReady: .evidenceReady
        case .transcriptsIdle: .transcriptsIdle
        case .factsDone: .factsDone
        case .tagsDone: .tagsDone
        case .feedsRefreshed: .feedsRefreshed
        case .editionPublished: .editionPublished
        case .episodesRemoved: .episodesRemoved
        case .changedElsewhere: .changedElsewhere
        }
    }
}
