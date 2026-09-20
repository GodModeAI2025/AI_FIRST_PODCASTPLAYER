//
//  Evidence.swift
//  PodcastAICore
//
//  Die Antwort auf den zentralen Befund aus dem BrainSpeak-Audit: dort endet
//  die Faktenextraktion in `markdownBullets: String` — Prosa ohne Herkunft.
//  Hier kann eine Aussage gar nicht erst entstehen, ohne zu sagen, wo sie
//  herkommt und wo man sie hören kann.
//

import Foundation

/// Eine belegbare Fundstelle: konkrete Medienfassung, konkreter Zeitbereich,
/// konkreter Originaltext.
///
/// Ein Modell darf eine ``EvidenceID`` **auswählen**. Es darf sie nicht
/// erfinden und keinen Zeitbereich selbst bestimmen — beides löst Swift auf.
public struct Evidence: Hashable, Codable, Sendable, Identifiable {

    public let id: EvidenceID

    /// Die Medienfassung, auf die sich der Zeitbereich bezieht. Ohne sie ist
    /// ein Timecode bedeutungslos: derselbe Inhalt kann in zwei Fassungen
    /// unterschiedlich lang sein.
    public let mediaVersionID: MediaVersionID
    public let episodeID: EpisodeID
    public let sourceID: SourceID

    /// Die Transkriptfassung, aus der der Text stammt. Eine Korrektur oder
    /// Neuanalyse erzeugt eine neue Revision statt den Text stillschweigend
    /// zu ersetzen.
    public let transcriptID: TranscriptID
    public let transcriptRevision: Revision

    /// Der Bereich im Medium. Bei ungetaktetem Publisher-Transkript `nil` —
    /// dann liefert die Fundstelle Wissen, aber keine Wiedergabe.
    public let range: MediaTimeRange?

    /// Der Originaltext dieser Stelle. Nie eine Zusammenfassung.
    public let quotedText: String

    /// Falls die Quelle einen Sprecher verlässlich ausweist. Ein aus dem Klang
    /// geratener Name ist kein Beleg — dann bleibt das Feld leer.
    public let attributedSpeaker: String?

    public init(
        id: EvidenceID,
        mediaVersionID: MediaVersionID,
        episodeID: EpisodeID,
        sourceID: SourceID,
        transcriptID: TranscriptID,
        transcriptRevision: Revision,
        range: MediaTimeRange?,
        quotedText: String,
        attributedSpeaker: String? = nil
    ) {
        self.id = id
        self.mediaVersionID = mediaVersionID
        self.episodeID = episodeID
        self.sourceID = sourceID
        self.transcriptID = transcriptID
        self.transcriptRevision = transcriptRevision
        self.range = range
        self.quotedText = quotedText
        self.attributedSpeaker = attributedSpeaker
    }

    /// Kann diese Fundstelle abgespielt werden? Ohne Zeitbereich nicht.
    public var isPlayable: Bool { range != nil && !(range?.isEmpty ?? true) }

    /// Kennung, die sich aus dem Inhalt ergibt. Zweimalige Analyse derselben
    /// Fassung erzeugt dieselbe Fundstelle statt eines Duplikats.
    public static func stableID(
        mediaVersionID: MediaVersionID,
        transcriptRevision: Revision,
        range: MediaTimeRange?
    ) -> EvidenceID {
        let rangeKey = range.map { "\($0.start.milliseconds)-\($0.end.milliseconds)" } ?? "untimed"
        return EvidenceID(stable: "\(mediaVersionID.rawValue)|\(transcriptRevision.value)|\(rangeKey)")
    }
}

/// Eine inhaltliche Aussage mit Herkunft.
///
/// Die vier Bestandteile aus FR-018 bleiben getrennte Felder statt eines
/// gemeinsamen Fließtexts: Aussage, neutrale Einordnung, persönliche Relevanz
/// und offene Frage sind verschiedene Dinge und dürfen nicht zu einem Absatz
/// verschmelzen.
public struct Claim: Hashable, Codable, Sendable, Identifiable {

    public let id: ClaimID

    /// Worum es geht — eine Aussage, kein Absatz.
    public let statement: String

    /// Neutrale Einordnung ohne Wertung. Optional.
    public let neutralSummary: String?

    /// Warum das für diesen Nutzer relevant ist, mit Bezug auf ein konkretes
    /// Interesse. Optional — nicht jede Aussage ist persönlich relevant.
    public let personalRelevance: PersonalRelevance?

    /// Eine Frage, die diese Aussage offen lässt. Speist den Breadcrumb-Trail.
    public let openQuestion: String?

    /// Mindestens eine Fundstelle. Eine Aussage ohne Beleg wird nicht persistiert.
    public let evidenceIDs: [EvidenceID]

    /// Woher der Text stammt. Bei `.derived` ist `statement` Modellformulierung,
    /// die Belege darunter bleiben Original.
    public let provenance: Provenance

    public let createdAt: Date

    public init(
        id: ClaimID,
        statement: String,
        neutralSummary: String? = nil,
        personalRelevance: PersonalRelevance? = nil,
        openQuestion: String? = nil,
        evidenceIDs: [EvidenceID],
        provenance: Provenance = .derived,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.statement = statement
        self.neutralSummary = neutralSummary
        self.personalRelevance = personalRelevance
        self.openQuestion = openQuestion
        self.evidenceIDs = evidenceIDs
        self.provenance = provenance
        self.createdAt = createdAt
    }

    /// Eine Aussage ohne Beleg ist kein gültiger Datensatz.
    public var isWellFormed: Bool {
        !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !evidenceIDs.isEmpty
    }
}

/// Die Begründung hinter „Warum für dich relevant?“.
///
/// Zeigt auf ein konkretes bestätigtes Interesse oder eine offene Frage —
/// nicht auf ein undurchsichtiges Ähnlichkeitsmaß.
public struct PersonalRelevance: Hashable, Codable, Sendable {

    public enum Reason: String, Codable, Sendable {
        /// Trifft ein vom Nutzer bestätigtes Interesse.
        case confirmedInterest
        /// Trifft ein aktuelles Vorhaben.
        case activeProject
        /// Beantwortet eine ausdrücklich gestellte offene Frage.
        case openQuestion
        /// Trifft ein vorgeschlagenes, noch nicht bestätigtes Interesse.
        case suggestedInterest

        /// Darf diese Begründung eine persönliche Ausgabe auslösen?
        /// Vermutete Interessen allein reichen dafür nicht.
        public var isConfirmedByUser: Bool {
            self != .suggestedInterest
        }
    }

    public let reason: Reason
    public let interestID: InterestID
    /// Der Anzeigename, wie ihn der Nutzer selbst eingetragen hat.
    public let interestLabel: String
    /// Ein Satz in der Sprache des Nutzers. Wird wörtlich angezeigt,
    /// damit „Warum sehe ich das?“ jederzeit beantwortbar ist.
    public let explanation: String

    public init(reason: Reason, interestID: InterestID, interestLabel: String, explanation: String) {
        self.reason = reason
        self.interestID = interestID
        self.interestLabel = interestLabel
        self.explanation = explanation
    }
}
