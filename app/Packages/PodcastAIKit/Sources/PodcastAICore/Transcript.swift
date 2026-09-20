//
//  Transcript.swift
//  PodcastAICore
//
//  Hier sitzt die Korrektur des schwerwiegendsten Befunds aus dem
//  BrainSpeak-Audit: dort trägt `TranscriptionResult` nur Text, ein
//  `isFinal`-Flag und eine **Wanduhrzeit**. Ein Segment ohne Medienzeit ist
//  für diese App wertlos — deshalb ist `range` hier keine Option, die man
//  vergessen kann, sondern Teil des Konstruktors.
//

import Foundation

/// Ein finalisierter Abschnitt eines Transkripts mit Bezug auf die Medienzeit.
public struct TranscriptSegment: Hashable, Codable, Sendable, Identifiable {

    public let id: SegmentID

    /// Der Bereich **im Medium**. Nicht Wanduhrzeit seit Analysebeginn.
    ///
    /// Wird eine Datei schneller als Echtzeit analysiert — der Normalfall —,
    /// dann unterscheiden sich beide um ein Vielfaches. Ein Wanduhrwert ergäbe
    /// plausible, aber falsche Timecodes: der gefährlichste Fehler, weil er
    /// erst beim Hören auffällt.
    public let range: MediaTimeRange

    public let text: String

    /// Sprecherkennzeichnung nur, wenn die Quelle sie verlässlich ausweist.
    /// Ein aus dem Klang gebildetes Cluster ist keine Personenidentifikation.
    public let speakerLabel: String?

    /// Zuversicht der Analyse, sofern die API sie liefert.
    public let confidence: Double?

    public init(
        id: SegmentID, range: MediaTimeRange, text: String,
        speakerLabel: String? = nil, confidence: Double? = nil
    ) {
        self.id = id; self.range = range; self.text = text
        self.speakerLabel = speakerLabel; self.confidence = confidence
    }

    public static func stableID(mediaVersionID: MediaVersionID, range: MediaTimeRange) -> SegmentID {
        SegmentID(stable: "\(mediaVersionID.rawValue)|\(range.start.milliseconds)|\(range.end.milliseconds)")
    }
}

/// Woher ein Transkript stammt. Entscheidet mit darüber, ob zeitgenaue
/// Wiedergabe möglich ist.
public enum TranscriptOrigin: String, Codable, Sendable {
    /// Vom Anbieter geliefert, mit Zeitmarken.
    case publisherTimed
    /// Vom Anbieter geliefert, ohne Zeitmarken.
    case publisherUntimed
    /// Aus dem Audio analysiert.
    case speechAnalysis
    /// Vom Nutzer korrigiert.
    case userCorrected

    public var providesMediaTiming: Bool {
        self != .publisherUntimed
    }
}

public struct Transcript: Hashable, Codable, Sendable, Identifiable {

    public let id: TranscriptID
    public let mediaVersionID: MediaVersionID
    public let revision: Revision
    public let origin: TranscriptOrigin
    public let locale: String

    /// Aufsteigend nach Startzeit. Bei ungetakteter Herkunft leer.
    public let segments: [TranscriptSegment]

    /// Nur bei ungetakteter Herkunft gefüllt: Text ohne Zeitbezug.
    /// Liefert Wissen, aber keine Fokuswiedergabe.
    public let untimedText: String?

    /// Welche Medienbereiche tatsächlich analysiert wurden. Ein Abbruch bei
    /// Minute 40 einer 90-Minuten-Folge ist sichtbar und wird nicht als
    /// vollständig ausgegeben.
    public let analyzedRanges: IntervalSet

    public let createdAt: Date

    public init(
        id: TranscriptID, mediaVersionID: MediaVersionID, revision: Revision,
        origin: TranscriptOrigin, locale: String, segments: [TranscriptSegment],
        untimedText: String? = nil, analyzedRanges: IntervalSet, createdAt: Date = Date()
    ) {
        self.id = id; self.mediaVersionID = mediaVersionID; self.revision = revision
        self.origin = origin; self.locale = locale
        self.segments = segments.sorted { $0.range < $1.range }
        self.untimedText = untimedText; self.analyzedRanges = analyzedRanges
        self.createdAt = createdAt
    }

    /// Darf aus diesem Transkript ein Hörplan gebaut werden?
    public var supportsFocusPlayback: Bool {
        origin.providesMediaTiming && !segments.isEmpty
    }

    /// Abdeckung bezogen auf die Gesamtlänge der Medienfassung.
    public func coverage(mediaDuration: MediaDuration?) -> AnalysisCoverage {
        guard let mediaDuration, mediaDuration.milliseconds > 0 else {
            return analyzedRanges.isEmpty ? .none : .complete
        }
        let whole = MediaTimeRange(start: .zero, duration: mediaDuration)
        let fraction = analyzedRanges.coverage(of: whole)
        if fraction <= 0 { return .none }
        // Die letzten Millisekunden liefert kaum ein Analyselauf mit.
        if fraction >= 0.995 { return .complete }
        return .partial(fraction: fraction, analyzed: analyzedRanges)
    }

    /// Alle Segmente, die den Bereich berühren — die Grundlage jedes Zitats.
    public func segments(overlapping range: MediaTimeRange) -> [TranscriptSegment] {
        segments.filter { $0.range.overlaps(range) }
    }

    /// Zusammenhängender Originaltext für einen Bereich.
    public func text(in range: MediaTimeRange) -> String {
        segments(overlapping: range).map(\.text).joined(separator: " ")
    }

    /// Dehnt einen Bereich auf die Segmentgrenzen aus, damit ein Zitat nicht
    /// mitten im Satz beginnt oder endet.
    public func snappedToSegmentBounds(_ range: MediaTimeRange) -> MediaTimeRange {
        let touching = segments(overlapping: range)
        guard let first = touching.first, let last = touching.last else { return range }
        return MediaTimeRange(start: min(range.start, first.range.start),
                              end: max(range.end, last.range.end))
    }
}
