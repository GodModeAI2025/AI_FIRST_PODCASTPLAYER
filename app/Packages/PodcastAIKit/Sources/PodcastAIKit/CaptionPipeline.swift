//
//  CaptionPipeline.swift
//  PodcastAIKit
//
//  Der Weg einer YouTube-Folge zu Transkript und Belegen.
//
//    Untertitel von Supadata → Segmente → Transkript → Passagen → Belege
//
//  Ab den Belegen ist alles wie bei einer Folge mit Ton: Fakten, Erwähnungen,
//  Kapitel und Chat lesen dieselben Datensätze. Die Zeitmarken beziehen sich
//  auf das Video. Deshalb hängt das Transkript an einer eigenen Medienfassung,
//  deren Adresse die des Videos ist, und abgespielt wird im YouTube-Player,
//  nie in der App.
//
//  Die Untertitel sind fremde Daten wie ein Feed: sie gehen als Belege an
//  das Modell, nie als Anweisung.
//

import Foundation
import PodcastAICore
import PodcastAISources
import PodcastAITranscription

public enum CaptionAnalysis {

    /// Die Medienfassung eines YouTube-Videos. Dieselbe Regel wie für
    /// Audiodateien: die Kennung folgt aus der Adresse.
    public static func mediaVersionID(watchURL: URL) -> MediaVersionID {
        MediaVersionID(stable: watchURL.absoluteString)
    }

    /// Zeilen von Supadata als Untertitelzeilen mit Medienzeit.
    public static func cues(from transcript: SupadataTranscript) -> [CaptionCue] {
        transcript.captions.map {
            CaptionCue(text: $0.text,
                       start: MediaTime(milliseconds: $0.offsetMilliseconds),
                       duration: MediaDuration(milliseconds: $0.durationMilliseconds))
        }
    }

    /// Passagen für die Belege. Untertitel haben selten Pausen von anderthalb
    /// Sekunden; geschnitten wird deshalb an jeder Segmentgrenze, sobald die
    /// Ziellänge erreicht ist. Segmente enden an Satzzeichen oder nach
    /// höchstens 15 Sekunden, ein Beleg beginnt also nicht mitten im Wort.
    public static func passages(for transcript: Transcript) -> [MediaTimeRange] {
        PassageBuilder.passages(from: transcript, gapThreshold: .zero)
    }

    public struct Result: Sendable {
        public let transcript: Transcript
        public let media: MediaVersion
        public let evidence: [Evidence]
    }

    /// Baut Transkript, Fassung und Belege. `nil`, wenn nach dem Reinigen
    /// kein Text übrig bleibt, etwa bei einem Video nur mit Musik.
    public static func build(
        captions: SupadataTranscript, episodeID: EpisodeID, sourceID: SourceID,
        watchURL: URL, fallbackLocale: String, declaredDuration: MediaDuration? = nil,
        origin: TranscriptOrigin = .youTubeCaptions
    ) -> Result? {
        let mediaVersionID = mediaVersionID(watchURL: watchURL)
        let locale = captions.lang.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLocale
        let transcript = CaptionTranscriptBuilder.transcript(
            from: cues(from: captions), mediaVersionID: mediaVersionID, locale: locale, origin: origin)
        guard let last = transcript.segments.last else { return nil }

        var duration = MediaDuration(milliseconds: last.range.end.milliseconds)
        if let declaredDuration, declaredDuration > duration { duration = declaredDuration }
        let media = MediaVersion(
            id: mediaVersionID, episodeID: episodeID, remoteURL: watchURL,
            duration: duration, mimeType: nil, supportsExactSeeking: false)
        let evidence = TranscriptAssembler().evidence(
            from: transcript, episodeID: episodeID, sourceID: sourceID,
            ranges: passages(for: transcript))
        guard !evidence.isEmpty else { return nil }
        return Result(transcript: transcript, media: media, evidence: evidence)
    }
}

#if canImport(SwiftData)
import PodcastAIPersistence

extension LibraryStore {

    /// Speichert, was `CaptionAnalysis.build` geliefert hat. Erst Fassung und
    /// Transkript, dann die Belege, wie bei einer Folge mit Ton.
    public func save(captions result: CaptionAnalysis.Result, forEpisode episodeID: EpisodeID) throws {
        try save(transcript: result.transcript, media: result.media, forEpisode: episodeID)
        try store(evidence: result.evidence)
    }
}
#endif
