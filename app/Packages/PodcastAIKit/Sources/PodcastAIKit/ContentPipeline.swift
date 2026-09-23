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
    /// Vom Nutzer abgebrochen. Eigene Stufe und ausdrücklich **nicht**
    /// `failed`: es ist nichts kaputt, es wurde gewollt. Der Unterschied
    /// steht auch in der Oberfläche — eine Warndreieck-Meldung für eine
    /// eigene Entscheidung wäre eine Belehrung.
    case cancelled

    public var label: String {
        switch self {
        case .discovered: "gefunden"
        case .mediaDownloaded: "geladen"
        case .transcribed: "transkribiert"
        case .evidenceExtracted: "erschlossen"
        case .failed: "fehlgeschlagen"
        case .cancelled: "abgebrochen"
        }
    }
}

/// Wie ein Analyselauf geendet hat.
///
/// Ein eigener Typ statt eines Booleschen: „fertig“ und „angehalten“ führen
/// zu verschiedenen nächsten Schritten, und ein `Bool` an dieser Stelle
/// hiesse, dass jeder Aufrufer sich merken muss, welcher Wert was bedeutet.
public enum AnalysisOutcome: Sendable {
    /// Durchgelaufen. Die Belege stehen in der Datenbank.
    case completed(evidence: [Evidence])
    /// An einem Prüfpunkt angehalten. Der Stand ist gesichert, der nächste
    /// Lauf setzt hier an.
    case checkpointed(resumePoint: MediaTime)

    public var isComplete: Bool {
        if case .completed = self { return true }
        return false
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

    /// Erschließt eine Folge — ganz oder bis zum nächsten Prüfpunkt.
    ///
    /// `locale` wird ausdrücklich übergeben und nicht aus dem Gerät geraten:
    /// ein deutschsprachiger Nutzer hört englische Podcasts, und ein Lauf in
    /// der falschen Sprache liefert Text, der wie ein Transkript aussieht,
    /// aber keiner ist.
    ///
    /// **Unterbrechbar und fortsetzbar.** Das ist keine Bequemlichkeit,
    /// sondern die Voraussetzung dafür, dass Erschliessen im Hintergrund
    /// überhaupt möglich ist: iOS gibt einer App beim Wechsel in den
    /// Hintergrund Sekunden und einem `BGProcessingTask` Minuten — beides
    /// reicht nicht für eine 90-Minuten-Folge. Wer nicht anhalten und
    /// weitermachen kann, fängt jedes Mal von vorn an und kommt nie an.
    ///
    /// Angehalten wird an einem Prüfpunkt: der Zwischenstand liegt dann in
    /// der Datenbank, und der nächste Lauf setzt dort an. Verloren geht
    /// höchstens der Abstand zum letzten Prüfpunkt.
    ///
    /// Der Audio-Hintergrundmodus wird dafür ausdrücklich **nicht** benutzt.
    /// Er ist für Wiedergabe da, nicht als Schlupfloch für Dauerarbeit.
    @discardableResult
    public func process(
        episode: Episode,
        audioURL: URL,
        sourceID: SourceID,
        locale: Locale
    ) async throws -> AnalysisOutcome {

        let mediaVersionID = MediaVersionID(stable: audioURL.absoluteString)

        onProgress(PipelineProgress(episodeID: episode.id, stage: .discovered))
        let media = try await obtainMedia(
            from: audioURL, mediaVersionID: mediaVersionID, episodeID: episode.id)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .mediaDownloaded,
            detail: media.duration?.shortDescription
        ))

        // Zwischenstand aufnehmen, falls es einen gibt.
        let previous = try? await store.partialTranscript(forMedia: mediaVersionID)
        var segments = previous?.segments ?? []
        var analyzedThrough = previous?.resumePoint ?? .zero
        let startAt = analyzedThrough
        if startAt > .zero {
            onProgress(PipelineProgress(
                episodeID: episode.id, stage: .mediaDownloaded,
                detail: "Fortsetzung ab \(startAt.timecode)"))
        }

        let mediaURL = mediaDirectory.appendingPathComponent(mediaVersionID.rawValue)
        var batch: [(range: MediaTimeRange, text: String, isFinal: Bool)] = []
        var lastCheckpoint = analyzedThrough
        var stoppedEarly = false

        /// Schreibt den Stand weg. Der Rückgabewert sagt, ob es geklappt hat —
        /// ein misslungener Prüfpunkt darf nicht so aussehen wie ein
        /// gelungener, sonst geht beim nächsten Lauf mehr verloren als gedacht.
        @discardableResult
        func checkpoint(partial: Bool) async throws -> Transcript {
            segments = assembler.merge(existing: segments, incoming: batch,
                                       mediaVersionID: mediaVersionID)
            batch.removeAll(keepingCapacity: true)

            let transcript = assembler.finish(
                segments: segments, mediaVersionID: mediaVersionID,
                locale: locale.identifier, origin: .speechAnalysis,
                previousRevision: previous?.revision,
                analyzedThrough: analyzedThrough,
                isPartial: partial
            )
            try await store.save(transcript: transcript, media: media, forEpisode: episode.id)
            lastCheckpoint = analyzedThrough
            return transcript
        }

        do {
            for try await result in try await engine.transcribeFile(
                at: mediaURL, mediaVersionID: mediaVersionID,
                locale: locale, startingAt: startAt
            ) {
                guard result.isFinal, let range = result.range else { continue }
                batch.append((range: range, text: result.text, isFinal: true))
                if range.end > analyzedThrough { analyzedThrough = range.end }

                // Prüfpunkt nach Medienzeit, nicht nach Anzahl Ergebnisse:
                // eine schweigsame Folge liefert wenige Ergebnisse über eine
                // lange Strecke, eine dichte viele über eine kurze. Nach
                // Anzahl gemessen wäre der Abstand zwischen zwei Prüfpunkten
                // beliebig — und genau der ist es, was ein Abbruch kostet.
                if analyzedThrough - lastCheckpoint >= Self.checkpointInterval {
                    try await checkpoint(partial: true)
                    onProgress(PipelineProgress(
                        episodeID: episode.id, stage: .transcribed,
                        detail: "gesichert bis \(analyzedThrough.timecode)"))
                }
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            stoppedEarly = true
        } catch {
            // Auch ein Netz- oder Dateifehler mitten im Lauf darf das
            // bisher Erarbeitete nicht wegwerfen.
            try? await checkpoint(partial: true)
            throw error
        }

        if stoppedEarly {
            try await checkpoint(partial: true)
            onProgress(PipelineProgress(
                episodeID: episode.id, stage: .transcribed,
                detail: "angehalten bei \(analyzedThrough.timecode)"))
            return .checkpointed(resumePoint: analyzedThrough)
        }

        // Derselbe Stand, der gerade gespeichert wurde -- nicht ein zweiter,
        // gleich aussehender. Zwei getrennt berechnete Transkripte wären
        // zwei Stellen, an denen sich ein Unterschied einschleichen kann.
        let transcript = try await checkpoint(partial: false)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .transcribed,
            detail: transcript.coverage(mediaDuration: media.duration).label
        ))

        let evidence = assembler.evidence(
            from: transcript, episodeID: episode.id, sourceID: sourceID,
            ranges: PassageBuilder.passages(from: transcript)
        )
        try await store.store(evidence: evidence)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .evidenceExtracted,
            detail: "\(evidence.count) Fundstellen"
        ))
        return .completed(evidence: evidence)
    }

    /// Wie viel Medienzeit höchstens zwischen zwei Prüfpunkten liegt.
    ///
    /// Fünf Minuten ist der Kompromiss: ein Abbruch kostet nie mehr als das,
    /// und bei einer 90-Minuten-Folge entstehen achtzehn Schreibvorgänge
    /// statt einem. Kleiner gewählt würde die Datenbank zur Bremse, grösser
    /// würde ein Abbruch teuer — und Abbrüche sind im Hintergrund der
    /// Normalfall, nicht die Ausnahme.
    static let checkpointInterval = MediaDuration(minutes: 5)

    /// Besorgt die Mediendatei — und lädt sie **nicht** erneut, wenn sie
    /// schon da ist.
    ///
    /// Ohne diese Prüfung kostete jede Fortsetzung einen vollständigen
    /// zweiten Download. Bei einer Analyse, die über mehrere
    /// Hintergrundfenster läuft, wäre das der teuerste Teil der ganzen
    /// Übung — und der sinnloseste.
    private func obtainMedia(
        from audioURL: URL, mediaVersionID: MediaVersionID, episodeID: EpisodeID
    ) async throws -> MediaVersion {

        let local = mediaDirectory.appendingPathComponent(mediaVersionID.rawValue)
        if FileManager.default.fileExists(atPath: local.path),
           let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0 {
            return MediaVersion(
                id: mediaVersionID, episodeID: episodeID, remoteURL: audioURL,
                localRelativePath: mediaVersionID.rawValue,
                byteCount: Int64(size),
                // Der Hash wird hier bewusst nicht neu gebildet: er steht
                // bereits in der Datenbank, und eine 200-MB-Datei erneut zu
                // lesen, nur um dasselbe herauszubekommen, ist bei jeder
                // Fortsetzung dieselbe verschenkte Minute.
                contentHash: nil,
                duration: try? AudioFileReader.duration(of: local)
            )
        }

        let download = try await downloader.download(from: audioURL, mediaVersionID: mediaVersionID)
        return MediaVersion(
            id: mediaVersionID, episodeID: episodeID, remoteURL: audioURL,
            localRelativePath: download.localRelativePath,
            byteCount: download.byteCount, contentHash: download.contentHash,
            duration: download.duration, mimeType: download.mimeType
        )
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
