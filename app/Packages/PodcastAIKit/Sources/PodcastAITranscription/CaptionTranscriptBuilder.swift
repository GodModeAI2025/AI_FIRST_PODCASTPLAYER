//
//  CaptionTranscriptBuilder.swift
//  PodcastAITranscription
//
//  Macht aus Untertitelzeilen ein Transkript mit Zeitmarken.
//
//  Untertitel sind keine Spracherkennung: die Zeilen sind kurz, überlappen
//  sich oft um ein paar hundert Millisekunden und tragen Marken wie
//  „[Musik]“ oder „[♪♪♪]“. Die Zusammenführung von `TranscriptAssembler`
//  passt dafür nicht, denn sie verwirft bei starker Überlappung die frühere
//  Zeile, gedacht für die Wiederaufnahme einer Analyse. Hier wird deshalb
//  geglättet statt verworfen: Marken raus, Zeilen zu Sätzen zusammen,
//  Überlappungen am Beginn der nächsten Zeile abgeschnitten.
//
//  Ohne Apple-Frameworks und ohne Netz, also prüfbar.
//

import Foundation
import PodcastAICore

/// Eine Untertitelzeile: Text, Beginn und Dauer im Video.
public struct CaptionCue: Hashable, Sendable {
    public let text: String
    public let start: MediaTime
    public let duration: MediaDuration

    public init(text: String, start: MediaTime, duration: MediaDuration) {
        self.text = text
        self.start = start
        self.duration = duration
    }
}

public enum CaptionText {

    /// Entfernt Marken und Zeilenumbrüche.
    ///
    /// Weg kommen eckige Klammern samt Inhalt („[Musik]“, „[Applause]“,
    /// „[♪♪♪]“), Notenzeichen, die Sprecherwechsel „>>“ und doppelte Leerzeichen.
    /// Übrig bleibt, was gesprochen wurde. Einfache HTML-Entitäten, die in
    /// Untertiteln vorkommen, werden zu Zeichen.
    public static func clean(_ raw: String) -> String {
        var text = raw
        for (entity, character) in [("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"),
                                    ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([♪♫\s]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[♪♫♬]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: ">>", with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Endet der Text mit einem Satzzeichen?
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”“’)» ")).last else {
            return false
        }
        return ".!?…".contains(last)
    }
}

public enum CaptionTranscriptBuilder {

    /// Höchstlänge eines Segments. Automatische Untertitel haben keine
    /// Satzzeichen; ohne Grenze würde aus einer Rede ein einziges Segment.
    public static let maxSegmentLength = MediaDuration(seconds: 15)

    /// Ab dieser Pause beginnt ein neues Segment, auch mitten im Satz.
    public static let pauseThreshold = MediaDuration(milliseconds: 1_500)

    /// Aus Zeilen werden Segmente: gereinigt, zeitlich geordnet, ohne
    /// Überlappung und zu Sätzen zusammengefasst.
    public static func segments(from cues: [CaptionCue], mediaVersionID: MediaVersionID) -> [TranscriptSegment] {
        // 1. Reinigen, Leeres weg, nach Beginn ordnen.
        let cleaned = cues
            .map { CaptionCue(text: CaptionText.clean($0.text), start: $0.start, duration: $0.duration) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
        guard !cleaned.isEmpty else { return [] }

        // 2. Zeitbereiche ohne Überlappung. Eine Zeile endet spätestens, wo
        // die nächste beginnt. Eine Zeile ohne Dauer reicht bis zur nächsten,
        // die letzte bekommt dann zwei Sekunden.
        var timed: [(range: MediaTimeRange, text: String)] = []
        for (index, cue) in cleaned.enumerated() {
            let next = index + 1 < cleaned.count ? cleaned[index + 1].start : nil
            var end = cue.duration.isZero ? (next ?? cue.start + MediaDuration(seconds: 2)) : cue.start + cue.duration
            if let next, end > next { end = next }
            // Zwei Zeilen mit demselben Beginn: die erste bekommt eine Millisekunde.
            if end <= cue.start { end = cue.start + MediaDuration(milliseconds: 1) }
            timed.append((MediaTimeRange(start: cue.start, end: end), cue.text))
        }

        // 3. Zu Sätzen zusammenfassen: bis zum Satzzeichen, bis zur Pause
        // oder bis zur Höchstlänge.
        var result: [TranscriptSegment] = []
        var start = timed[0].range.start
        var end = timed[0].range.end
        var parts = [timed[0].text]

        func flush() {
            let range = MediaTimeRange(start: start, end: end)
            let text = parts.joined(separator: " ")
            guard !range.isEmpty, !text.isEmpty else { return }
            result.append(TranscriptSegment(
                id: TranscriptSegment.stableID(mediaVersionID: mediaVersionID, range: range),
                range: range, text: text))
        }

        for item in timed.dropFirst() {
            let gap = item.range.start - end
            let sentenceDone = CaptionText.endsSentence(parts.last ?? "")
            let tooLong = item.range.end - start > maxSegmentLength
            if sentenceDone || tooLong || (item.range.start > end && gap >= pauseThreshold) {
                flush()
                start = item.range.start
                parts = []
            }
            parts.append(item.text)
            end = max(end, item.range.end)
        }
        flush()
        return result
    }

    /// Das fertige Transkript. Die Sprache bestimmt mit die Kennung, eine
    /// zweite Sprache desselben Videos ist ein eigenes Transkript.
    public static func transcript(
        from cues: [CaptionCue], mediaVersionID: MediaVersionID, locale: String,
        origin: TranscriptOrigin = .youTubeCaptions
    ) -> Transcript {
        let segments = segments(from: cues, mediaVersionID: mediaVersionID)
        return TranscriptAssembler().finish(
            segments: segments, mediaVersionID: mediaVersionID, locale: locale,
            origin: origin, analyzedThrough: segments.last?.range.end)
    }
}
