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

    /// Die Adresse, die an Supadata geht und an der die Medienfassung eines
    /// Videos hängt: bei YouTube die Adresse des Videos ohne Anhängsel, bei
    /// TikTok, Instagram, X und Facebook die des Beitrags. Folgen mit Ton
    /// haben keine.
    public static func captionURL(of episode: Episode) -> URL? {
        guard episode.audioURL == nil else { return nil }
        if let watch = YouTubeLinks.canonicalWatchURL(for: episode.webPageURL) { return watch }
        guard let page = episode.webPageURL, case .post(_, let url)? = SocialLinks.classify(page) else { return nil }
        return url
    }

    /// Auf welche Fassung der Feed einer Folge zeigt: die Audiodatei, bei
    /// einem Video dessen Adresse. Die Regel des Wächters im Store.
    public static func feedMediaVersionID(of episode: Episode) -> MediaVersionID? {
        if let audio = episode.audioURL { return MediaVersionID(stable: audio.absoluteString) }
        return captionURL(of: episode).map(mediaVersionID(watchURL:))
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
        public let sourceID: SourceID
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
        return Result(transcript: transcript, media: media, evidence: evidence, sourceID: sourceID)
    }
}

/// Wie aus einem Transkript Belege werden. Die Passagen richten sich nach
/// der Herkunft: Untertitel werden an jeder Segmentgrenze geschnitten,
/// sobald die Ziellänge erreicht ist, Ton und Transkripte der Podcasts an
/// Sprechpausen. So entstehen aus einem Transkript immer dieselben Belege,
/// gleich welcher Weg es zuerst gespeichert hat.
public enum EvidenceRecipe {

    public static func passages(for transcript: Transcript) -> [MediaTimeRange] {
        switch transcript.origin {
        case .youTubeCaptions, .postCaptions, .youTubeCaptionsAligned:
            CaptionAnalysis.passages(for: transcript)
        case .publisherTimed, .publisherUntimed, .speechAnalysis, .userCorrected:
            PassageBuilder.passages(from: transcript)
        }
    }

    public static func evidence(from transcript: Transcript, episodeID: EpisodeID, sourceID: SourceID) -> [Evidence] {
        TranscriptAssembler().evidence(
            from: transcript, episodeID: episodeID, sourceID: sourceID, ranges: passages(for: transcript))
    }
}

#if canImport(SwiftData)
import PodcastAIPersistence

extension LibraryStore {

    /// Speichert, was `CaptionAnalysis.build` geliefert hat: Fassung,
    /// Transkript und Belege in einem Schritt, hinter dem Wächter, wie bei
    /// einer Folge mit Ton.
    public func commit(
        captions result: CaptionAnalysis.Result, under commitGuard: CommitGuard
    ) throws -> CommitResult<[Evidence]> {
        let episodeID = commitGuard.episodeID
        let sourceID = result.sourceID
        return try commit(
            transcript: result.transcript, media: result.media, evidence: result.evidence,
            rebuild: { EvidenceRecipe.evidence(from: $0, episodeID: episodeID, sourceID: sourceID) },
            under: commitGuard)
    }
}
#endif
