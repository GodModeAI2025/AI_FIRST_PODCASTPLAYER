//
//  TranscriptAssembler.swift
//  PodcastAITranscription
//
//  Setzt aus einem Strom von Analyseergebnissen ein Transkript zusammen.
//
//  Bewusst ohne Apple-Frameworks: die Zusammenführung — Reihenfolge,
//  Überlappungsdeduplizierung, Abdeckungsrechnung — ist reine Logik und
//  damit prüfbar, ohne ein Sprachmodell zu laden.
//

import Foundation
import PodcastAICore

public struct TranscriptAssembler: Sendable {

    /// Ab dieser Überlappung gelten zwei Segmente als dieselbe Stelle.
    /// Bei Wiederaufnahme wird ein Überlappungsbereich erneut analysiert;
    /// die Ergebnisse sind ähnlich, aber selten wortgleich.
    public static let overlapThreshold = 0.6

    public init() {}

    /// Fügt neue Ergebnisse in bestehende Segmente ein.
    ///
    /// - Vorläufige Ergebnisse werden verworfen — nur finalisierte kommen
    ///   in ein Transkript.
    /// - Ergebnisse ohne Zeitbereich werden verworfen: ein Segment ohne
    ///   Medienzeit ist für diese App nicht verwertbar und darf nicht mit
    ///   einem geratenen Zeitwert gerettet werden.
    /// - Bei Überlappung gewinnt das **neuere** Ergebnis: es stammt aus dem
    ///   vollständigeren Durchlauf.
    public func merge(
        existing: [TranscriptSegment],
        incoming: [(range: MediaTimeRange, text: String, isFinal: Bool)],
        mediaVersionID: MediaVersionID
    ) -> [TranscriptSegment] {

        var result: [TranscriptSegment] = []

        // Bestand zuerst durch dieselbe Einfügeregel schicken. In der Praxis
        // kommt er aus einem früheren Lauf und ist bereits sauber — aber ein
        // von der Platte geladenes Transkript einer älteren Fassung darf die
        // Invariante nicht brechen können. Die Zusage „keine Dubletten“ soll
        // ohne Vorbedingung gelten.
        for segment in existing {
            insert(range: segment.range, text: segment.text,
                   speakerLabel: segment.speakerLabel, confidence: segment.confidence,
                   mediaVersionID: mediaVersionID, into: &result)
        }

        for item in incoming {
            guard item.isFinal else { continue }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !item.range.isEmpty else { continue }
            insert(range: item.range, text: text, speakerLabel: nil, confidence: nil,
                   mediaVersionID: mediaVersionID, into: &result)
        }

        return result.sorted { $0.range < $1.range }
    }

    /// Fügt ein Segment ein und verdrängt dabei alles, was sich stark genug
    /// überlappt. Das später eingefügte gewinnt: bei der Wiederaufnahme
    /// stammt es aus dem vollständigeren Durchlauf.
    private func insert(
        range: MediaTimeRange, text: String, speakerLabel: String?, confidence: Double?,
        mediaVersionID: MediaVersionID, into result: inout [TranscriptSegment]
    ) {
        guard !range.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        result.removeAll { candidate in
            guard let overlap = candidate.range.intersection(range) else { return false }
            let shorter = min(candidate.range.duration.milliseconds, range.duration.milliseconds)
            guard shorter > 0 else { return false }
            return Double(overlap.duration.milliseconds) / Double(shorter) >= Self.overlapThreshold
        }

        result.append(TranscriptSegment(
            id: TranscriptSegment.stableID(mediaVersionID: mediaVersionID, range: range),
            range: range,
            text: trimmed,
            speakerLabel: speakerLabel,
            confidence: confidence
        ))
    }

    /// Baut das fertige Transkript und rechnet die tatsächliche Abdeckung aus.
    ///
    /// Die Abdeckung entsteht aus den Segmenten selbst, nicht aus einer
    /// Annahme über den Analyselauf: eine Folge mit zehn Minuten Stille am
    /// Ende hat dort keine Segmente und ist dort auch nicht abgedeckt.
    public func finish(
        segments: [TranscriptSegment],
        mediaVersionID: MediaVersionID,
        locale: String,
        origin: TranscriptOrigin,
        previousRevision: Revision? = nil,
        analyzedThrough: MediaTime? = nil,
        isPartial: Bool = false
    ) -> Transcript {

        let sorted = segments.sorted { $0.range < $1.range }
        var analyzed = IntervalSet(sorted.map(\.range))

        // Der eingespeiste Bereich ist analysiert, auch wo nichts gesprochen
        // wurde. Ohne diese Ergänzung sähe eine Folge mit Musikpassagen wie
        // eine abgebrochene Analyse aus.
        if let analyzedThrough, analyzedThrough.milliseconds > 0 {
            analyzed = analyzed.union(
                MediaTimeRange(start: .zero, end: analyzedThrough)
            )
        }

        return Transcript(
            id: TranscriptID(stable: "\(mediaVersionID.rawValue)|\(locale)"),
            mediaVersionID: mediaVersionID,
            revision: previousRevision?.next() ?? .initial,
            origin: origin,
            locale: locale,
            segments: sorted,
            analyzedRanges: analyzed,
            isPartial: isPartial
        )
    }

    /// Erzeugt Belege aus Transkriptsegmenten.
    ///
    /// Jede Fundstelle trägt damit von Anfang an Fassung, Revision, Zeit und
    /// Originaltext. Es gibt keinen Weg, einen Beleg ohne diese Angaben zu
    /// erzeugen — das ist die strukturelle Antwort auf den Audit-Befund.
    public func evidence(
        from transcript: Transcript,
        episodeID: EpisodeID,
        sourceID: SourceID,
        ranges: [MediaTimeRange]
    ) -> [Evidence] {
        ranges.compactMap { range in
            let snapped = transcript.snappedToSegmentBounds(range)
            let text = transcript.text(in: snapped)
            guard !text.isEmpty else { return nil }

            return Evidence(
                id: Evidence.stableID(
                    mediaVersionID: transcript.mediaVersionID,
                    transcriptRevision: transcript.revision,
                    range: snapped
                ),
                mediaVersionID: transcript.mediaVersionID,
                episodeID: episodeID,
                sourceID: sourceID,
                transcriptID: transcript.id,
                transcriptRevision: transcript.revision,
                range: snapped,
                quotedText: text,
                attributedSpeaker: transcript.segments(overlapping: snapped)
                    .compactMap(\.speakerLabel).first
            )
        }
    }
}
