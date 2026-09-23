//
//  FactAnchor.swift
//  PodcastAIKnowledge
//
//  Wo eine Aussage in der Folge fällt.
//
//  Ein Fakt zeigt auf seinen Beleg, und ein Beleg ist eine Passage von ein
//  bis zweieinhalb Minuten. Wer auf die Zeitmarke tippt, will den Satz
//  hören und nicht den Anfang der Passage. Das Modell wählt nur den Beleg
//  aus. Die Zeitmarke setzt dieser Code: er sucht im Beleg den Satz, der
//  die meisten Wörter mit der Aussage teilt, seltene Wörter zählen mehr.
//

import Foundation
import PodcastAICore

public enum FactAnchor {

    /// Der Satz im Beleg, der am besten zur Aussage passt, als Zeitbereich.
    ///
    /// Gesucht wird nur unter den Transkriptsegmenten, die den Bereich des
    /// Belegs berühren. `nil`, wenn keines ein Wort mit der Aussage teilt;
    /// dann bleibt der Aufrufer beim Bereich des Belegs.
    public static func range(
        for statement: String, within passage: MediaTimeRange, in segments: [TranscriptSegment]
    ) -> MediaTimeRange? {
        let inside = segments.filter { $0.range.overlaps(passage) }
        guard let best = bestIndex(for: statement, among: inside.map(\.text)) else { return nil }
        return inside[best].range
    }

    /// Setzt die Zeitmarken von Fakten auf ihren Satz, soweit sie noch auf
    /// eine ganze Passage zeigen.
    ///
    /// Ein Fakt gilt als schon verankert, wenn sein Bereich kürzer ist als
    /// `passageThreshold`. Sätze dauern Sekunden, Passagen Minuten.
    public static func anchored(
        _ facts: [EpisodeFact], in transcript: Transcript,
        passageThreshold: MediaDuration = MediaDuration(seconds: 30)
    ) -> [EpisodeFact] {
        facts.map { fact in
            guard fact.mediaVersionID == transcript.mediaVersionID,
                  fact.range.duration.milliseconds >= passageThreshold.milliseconds,
                  let sentence = range(for: fact.statement, within: fact.range, in: transcript.segments),
                  sentence != fact.range
            else { return fact }
            return EpisodeFact(
                id: fact.id, episodeID: fact.episodeID, sourceID: fact.sourceID,
                evidenceID: fact.evidenceID, mediaVersionID: fact.mediaVersionID,
                statement: fact.statement, range: sentence, modelTier: fact.modelTier)
        }
    }

    /// Der Wortlaut hinter einer Aussage: der passende Satz aus dem Text des
    /// Belegs, bei einem sehr kurzen Satz mit dem folgenden. Ohne Treffer
    /// der Anfang des Belegs.
    public static func wording(for statement: String, in passage: String, limit: Int = 400) -> String {
        let sentences = sentences(passage)
        guard let best = bestIndex(for: statement, among: sentences) else {
            return clipped(passage.trimmingCharacters(in: .whitespacesAndNewlines), limit)
        }
        var text = sentences[best]
        if text.count < 80, best + 1 < sentences.count { text += " " + sentences[best + 1] }
        return clipped(text, limit)
    }

    // MARK: - Hilfen

    /// Index des Textes mit der größten gewichteten Wortüberschneidung.
    /// Ein Wort, das in jedem Satz steht, sagt wenig und wiegt wenig. Bei
    /// Gleichstand gewinnt der frühere Satz.
    static func bestIndex(for statement: String, among texts: [String]) -> Int? {
        let wanted = Set(PassageRanker.terms(statement))
        guard !wanted.isEmpty, !texts.isEmpty else { return nil }
        let documents = texts.map { Set(PassageRanker.terms($0)).intersection(wanted) }
        var frequency: [String: Int] = [:]
        for document in documents {
            for term in document { frequency[term, default: 0] += 1 }
        }
        let count = Double(documents.count)
        var best: (index: Int, score: Double)?
        for (index, shared) in documents.enumerated() where !shared.isEmpty {
            let score = shared.reduce(0.0) { $0 + log(1 + count / Double(frequency[$1] ?? 1)) }
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        return best?.index
    }

    /// Zerlegt Text in Sätze: nach Punkt, Ausrufe- oder Fragezeichen und
    /// Auslassungspunkten, sobald ein Leerraum folgt.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var afterTerminator = false
        for character in text {
            if afterTerminator, character.isWhitespace {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
                afterTerminator = false
                continue
            }
            current.append(character)
            afterTerminator = ".!?…".contains(character)
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + " …"
    }
}
