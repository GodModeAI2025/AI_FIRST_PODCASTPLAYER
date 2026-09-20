//
//  ContentPipeline.swift
//  PodcastAIKit
//
//  Der Weg von „abonniert“ zu „persönliche Ausgabe“.
//
//    Folge auswählen → Medium laden → Transkript → Belege
//    → Relevanz → Kandidaten → Ausgabe
//
//  Jede Stufe ist unterbrechbar und erzeugt idempotente Artefakte: zweimal
//  dieselbe Stufe laufen zu lassen kostet Zeit, aber erzeugt keine
//  Dubletten. Das ist die Voraussetzung dafür, unter den Ressourcenregeln
//  des Systems überhaupt im Hintergrund zu arbeiten — Arbeit muss jederzeit
//  angehalten werden können, ohne etwas zu beschädigen.
//

import Foundation
import PodcastAICore
import PodcastAIMedia
import PodcastAIIntelligence
import PodcastAIKnowledge
import PodcastAISmartFeeds

#if canImport(SwiftData)
import PodcastAIPersistence
#endif

#if canImport(Speech)
import PodcastAITranscription
#endif

/// Welche Stufe eine Folge erreicht hat.
///
/// Die Zustände sind getrennt, weil sie für den Nutzer Verschiedenes
/// bedeuten: „gefunden“ ist nicht „analysierbar“, und „erschlossen“ ist
/// nicht „gehört“. Das Paket verlangt diese Trennung ausdrücklich.
public enum ProcessingStage: String, Sendable, Codable, CaseIterable {
    case discovered
    case mediaDownloaded
    case transcribed
    case evidenceExtracted
    case failed

    public var label: String {
        switch self {
        case .discovered: "gefunden"
        case .mediaDownloaded: "geladen"
        case .transcribed: "transkribiert"
        case .evidenceExtracted: "erschlossen"
        case .failed: "fehlgeschlagen"
        }
    }
}

public struct PipelineProgress: Sendable {
    public let episodeID: EpisodeID
    public let stage: ProcessingStage
    public let detail: String?

    public init(episodeID: EpisodeID, stage: ProcessingStage, detail: String? = nil) {
        self.episodeID = episodeID; self.stage = stage; self.detail = detail
    }
}

/// Fasst Transkriptsegmente zu Passagen zusammen.
///
/// Ohne Apple-Frameworks und deshalb prüfbar. Die Ziellänge ist ein
/// Kompromiss: kurz genug, dass eine Fundstelle wirklich eine Stelle ist,
/// lang genug, dass sie beim Anhören einen Gedanken trägt. Geschnitten wird
/// an Sprechpausen, nicht mitten im Satz.
public enum PassageBuilder {

    public static func passages(
        from transcript: Transcript,
        target: MediaDuration = MediaDuration(seconds: 60),
        gapThreshold: MediaDuration = MediaDuration(milliseconds: 1_500),
        hardLimit: MediaDuration = MediaDuration(seconds: 150)
    ) -> [MediaTimeRange] {

        guard let first = transcript.segments.first else { return [] }

        var result: [MediaTimeRange] = []
        var start = first.range.start
        var end = first.range.end

        for segment in transcript.segments.dropFirst() {
            let gap = segment.range.start.milliseconds - end.milliseconds
            let length = end.milliseconds - start.milliseconds

            let longEnough = length >= target.milliseconds
            let clearPause = gap >= gapThreshold.milliseconds

            // Schneiden bei erreichter Ziellänge **und** Pause — oder
            // spätestens, wenn die harte Grenze erreicht ist. Ohne die
            // Grenze erzeugt ein Sprecher ohne Pausen eine Passage von
            // zwanzig Minuten.
            if (longEnough && clearPause) || length >= hardLimit.milliseconds {
                result.append(MediaTimeRange(start: start, end: end))
                start = segment.range.start
            }
            end = segment.range.end
        }
        result.append(MediaTimeRange(start: start, end: end))
        return result.filter { !$0.isEmpty }
    }
}

#if canImport(SwiftData) && canImport(Speech)

public actor ContentPipeline {

    private let store: LibraryStore
    private let mediaDirectory: URL
    private let downloader: MediaDownloader
    private let engine = TimedTranscriptionEngine()
    private let assembler = TranscriptAssembler()
    private let scorer = RelevanceScorer()
    private let onProgress: @Sendable (PipelineProgress) -> Void

    public init(
        store: LibraryStore,
        mediaDirectory: URL,
        onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) {
        self.store = store
        self.mediaDirectory = mediaDirectory
        self.downloader = MediaDownloader(directory: mediaDirectory)
        self.onProgress = onProgress
    }

    /// Erschließt eine Folge vollständig.
    ///
    /// `locale` wird ausdrücklich übergeben und nicht aus dem Gerät geraten:
    /// ein deutschsprachiger Nutzer hört englische Podcasts, und ein Lauf in
    /// der falschen Sprache liefert Text, der wie ein Transkript aussieht,
    /// aber keiner ist.
    @discardableResult
    public func process(
        episode: Episode,
        audioURL: URL,
        sourceID: SourceID,
        locale: Locale
    ) async throws -> [Evidence] {

        let mediaVersionID = MediaVersionID(stable: audioURL.absoluteString)

        onProgress(PipelineProgress(episodeID: episode.id, stage: .discovered))
        let download = try await downloader.download(from: audioURL, mediaVersionID: mediaVersionID)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .mediaDownloaded,
            detail: download.duration?.shortDescription
        ))

        let mediaURL = mediaDirectory.appendingPathComponent(mediaVersionID.rawValue)
        var segments: [TranscriptSegment] = []
        var analyzedThrough = MediaTime.zero
        var batch: [(range: MediaTimeRange, text: String, isFinal: Bool)] = []

        for try await result in try await engine.transcribeFile(
            at: mediaURL, mediaVersionID: mediaVersionID, locale: locale
        ) {
            guard result.isFinal, let range = result.range else { continue }
            batch.append((range: range, text: result.text, isFinal: true))
            if range.end > analyzedThrough { analyzedThrough = range.end }

            // In Schüben zusammenführen statt je Ergebnis: das hält die
            // Deduplizierung billig und schafft einen sicheren Punkt zum
            // Anhalten.
            if batch.count >= 50 {
                segments = assembler.merge(existing: segments, incoming: batch,
                                           mediaVersionID: mediaVersionID)
                batch.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
            }
        }
        if !batch.isEmpty {
            segments = assembler.merge(existing: segments, incoming: batch,
                                       mediaVersionID: mediaVersionID)
        }

        let transcript = assembler.finish(
            segments: segments, mediaVersionID: mediaVersionID,
            locale: locale.identifier, origin: .speechAnalysis,
            analyzedThrough: analyzedThrough
        )
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .transcribed,
            detail: transcript.coverage(mediaDuration: download.duration).label
        ))

        // Erst Fassung und Transkript, dann die Belege. Die Reihenfolge ist
        // kein Zufall: ein Beleg verweist auf Fassung und Transkriptrevision,
        // und ein Verweis auf etwas, das noch nicht da ist, wäre genau die
        // Art von halber Herkunft, die diese Kette verhindern soll.
        try await store.save(
            transcript: transcript,
            media: MediaVersion(
                id: mediaVersionID,
                episodeID: episode.id,
                remoteURL: audioURL,
                localRelativePath: download.localRelativePath,
                byteCount: download.byteCount,
                contentHash: download.contentHash,
                duration: download.duration,
                mimeType: download.mimeType
            ),
            forEpisode: episode.id
        )

        let evidence = assembler.evidence(
            from: transcript, episodeID: episode.id, sourceID: sourceID,
            ranges: PassageBuilder.passages(from: transcript)
        )
        try await store.store(evidence: evidence)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .evidenceExtracted,
            detail: "\(evidence.count) Fundstellen"
        ))
        return evidence
    }

    /// Baut Kandidaten für eine persönliche Ausgabe.
    ///
    /// Reihenfolge: deterministische Vorauswahl, dann — sofern verfügbar —
    /// Modellbestätigung. Das Modell kann die Auswahl nur **verengen**, nie
    /// erweitern: es sieht ausschließlich, was die Vorauswahl zugelassen hat.
    /// Fällt es aus, entsteht die Ausgabe trotzdem und ist als nur
    /// stichwortbasiert erkennbar.
    public func candidates(
        for feed: SmartPodcastFeed,
        profile: InterestProfile,
        availability: ModelStatus,
        titles: [EpisodeID: (source: String, episode: String, published: Date?)] = [:]
    ) async throws -> [SegmentCandidate] {

        let evidence = try await store.evidenceForAnalyzedEpisodes()
        guard !evidence.isEmpty else { return [] }

        var matches = scorer.score(evidence: evidence, profile: profile)
        let feedTopics = Set(feed.topicIDs)
        if !feedTopics.isEmpty {
            matches = matches.filter { feedTopics.contains($0.interestID) }
        }
        guard !matches.isEmpty else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })

        var confirmed: Set<EvidenceID>?
        if case .success = availability.resolve(.recommend) {
            let shortlist = matches.compactMap { byID[$0.evidenceID] }
            if let selection = try? await KnowledgeExtractor()
                .selectRelevant(from: shortlist, profile: profile, availability: availability) {
                confirmed = Set(selection.evidenceIDs)
            }
        }

        return matches.compactMap { match -> SegmentCandidate? in
            guard let item = byID[match.evidenceID] else { return nil }
            if let confirmed, !confirmed.contains(match.evidenceID) { return nil }

            let stamped = RelevanceMatch(
                evidenceID: match.evidenceID, interestID: match.interestID,
                interestLabel: match.interestLabel, kind: match.kind,
                score: match.score, matchedTerms: match.matchedTerms,
                isModelConfirmed: confirmed?.contains(match.evidenceID) ?? false
            )
            let title = titles[item.episodeID]
            return SegmentCandidate(
                evidence: item, episodeID: item.episodeID, sourceID: item.sourceID,
                // „Unbekannte Quelle“ statt „Quelle“: falls es doch einmal
                // erscheint, soll es als fehlende Angabe lesbar sein und
                // nicht als Titel.
                sourceTitle: title?.source ?? "Unbekannte Quelle",
                episodeTitle: title?.episode ?? "Unbekannte Folge",
                originalPublishedAt: title?.published,
                transcriptRevision: item.transcriptRevision,
                topicIDs: [match.interestID],
                reason: stamped.explanation(),
                relevanceScore: match.score
            )
        }
    }
}
#endif
