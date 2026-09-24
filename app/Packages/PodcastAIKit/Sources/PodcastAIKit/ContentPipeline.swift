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
import PodcastAISources

#if canImport(SwiftData)
import PodcastAIPersistence
#endif

#if canImport(Speech)
import PodcastAITranscription
#endif

/// Welche Stufe eine Folge erreicht hat.
///
/// Die Zustände sind getrennt, weil sie für den Nutzer Verschiedenes
/// bedeuten: „gefunden“ ist nicht „analysierbar“, und „Transkript fertig“
/// ist nicht „gehört“. Das Paket verlangt diese Trennung ausdrücklich.
public enum ProcessingStage: String, Sendable, Codable, CaseIterable {
    case discovered
    case mediaDownloaded
    case transcribed
    case evidenceExtracted
    case failed

    public var label: String {
        switch self {
        case .discovered: String(localized: "gefunden", bundle: .module)
        case .mediaDownloaded: String(localized: "geladen", bundle: .module)
        case .transcribed: String(localized: "transkribiert", bundle: .module)
        case .evidenceExtracted: String(localized: "Transkript fertig", bundle: .module)
        case .failed: String(localized: "fehlgeschlagen", bundle: .module)
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

    /// Erstellt das Transkript einer Folge und daraus die Fundstellen.
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

        // Liefert der Podcast ein Transkript mit Zeitmarken, gilt es zuerst.
        // Klappt das nicht, bleibt es bei der eigenen Spracherkennung.
        if let transcriptURL = episode.timedTranscriptURL,
           let evidence = try await processPublisherTranscript(
               episode: episode, transcriptURL: transcriptURL, audioURL: audioURL,
               mediaVersionID: mediaVersionID, sourceID: sourceID, locale: locale) {
            return evidence
        }
        // Liegt die Datei schon da, wird sie nicht ein zweites Mal geladen.
        let download: DownloadResult
        if let existing = await downloader.existing(mediaVersionID: mediaVersionID) {
            download = existing
        } else {
            download = try await downloader.download(from: audioURL, mediaVersionID: mediaVersionID)
        }
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
            detail: String(AttributedString(
                localized: "^[\(evidence.count) Fundstelle](inflect: true)", bundle: .module).characters)
        ))
        return evidence
    }

    /// Session für Anbietertranskripte, mit den Prüfungen aus `SafeHTTP`.
    private lazy var transcriptSession = SafeHTTP.makeSession { configuration in
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
    }

    /// Weniger Stücke als das gilt nicht als Transkript der Folge.
    static let minimumPublisherCues = 3

    /// Übernimmt das Transkript des Anbieters (`podcast:transcript`).
    ///
    /// Die Zeiten gelten für die Audiodatei aus dem Feed, deshalb hängt das
    /// Transkript an derselben Fassung wie eine eigene Erkennung. Gibt `nil`
    /// zurück, wenn die Datei fehlt, nicht lesbar ist oder zu wenig enthält.
    /// Dann transkribiert die App selbst. Nur ein Abbruch geht weiter nach
    /// oben.
    private func processPublisherTranscript(
        episode: Episode, transcriptURL: URL, audioURL: URL,
        mediaVersionID: MediaVersionID, sourceID: SourceID, locale: Locale
    ) async throws -> [Evidence]? {
        let cues: [PublisherTranscript.Cue]
        do {
            let data = try await SafeHTTP.load(transcriptURL, using: transcriptSession, limit: SafeHTTP.textLimit)
            cues = try PublisherTranscript.parse(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
        guard cues.count >= Self.minimumPublisherCues else { return nil }
        try Task.checkCancellation()

        let segments = cues.map { cue in
            TranscriptSegment(
                id: TranscriptSegment.stableID(mediaVersionID: mediaVersionID, range: cue.range),
                range: cue.range, text: cue.text, speakerLabel: cue.speaker)
        }
        let analyzedThrough = segments.map(\.range.end).max() ?? .zero
        let transcript = assembler.finish(
            segments: segments, mediaVersionID: mediaVersionID,
            locale: locale.identifier, origin: .publisherTimed,
            analyzedThrough: analyzedThrough
        )
        // Liegt die Datei schon auf dem Gerät, bleibt sie an der Fassung.
        let local = await downloader.existing(mediaVersionID: mediaVersionID)
        try await store.save(
            transcript: transcript,
            media: MediaVersion(
                id: mediaVersionID,
                episodeID: episode.id,
                remoteURL: audioURL,
                localRelativePath: local?.localRelativePath,
                byteCount: local?.byteCount,
                contentHash: local?.contentHash,
                duration: local?.duration ?? episode.declaredDuration,
                mimeType: local?.mimeType
            ),
            forEpisode: episode.id
        )
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .transcribed,
            detail: String(localized: "Transkript vom Podcast", bundle: .module)
        ))

        let evidence = assembler.evidence(
            from: transcript, episodeID: episode.id, sourceID: sourceID,
            ranges: PassageBuilder.passages(from: transcript)
        )
        try await store.store(evidence: evidence)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .evidenceExtracted,
            detail: String(AttributedString(
                localized: "^[\(evidence.count) Fundstelle](inflect: true)", bundle: .module).characters)
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
                sourceTitle: title?.source ?? String(localized: "Unbekannte Quelle", bundle: .module),
                episodeTitle: title?.episode ?? String(localized: "Unbekannte Folge", bundle: .module),
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
