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
    /// Wie weit das Transkript der Folge ist, von 0 bis 1. Nur während der
    /// Erkennung gesetzt, und nur, wenn die Länge der Datei bekannt ist.
    public let fraction: Double?

    public init(episodeID: EpisodeID, stage: ProcessingStage, detail: String? = nil, fraction: Double? = nil) {
        self.episodeID = episodeID; self.stage = stage; self.detail = detail; self.fraction = fraction
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

/// Untertitel des YouTube-Zwillings einer Audiofolge, geholt von der App
/// nach ihren Regeln für Schlüssel, Netz und Wartezeiten.
public struct TwinCaptions: Sendable {
    public let captions: SupadataTranscript
    public let videoID: String
    public let channelID: String?

    public init(captions: SupadataTranscript, videoID: String, channelID: String?) {
        self.captions = captions
        self.videoID = videoID
        self.channelID = channelID
    }
}

/// Wie der Abgleich der Untertitel mit dem Ton ausging.
public enum TwinAlignmentOutcome: Equatable, Sendable {
    /// Gespeichert. `constant`: überall derselbe Versatz.
    case aligned(constant: Bool, anchors: Int)
    /// Die Untertitel sind in einer anderen Sprache als die Folge.
    case languageMismatch
    /// Die Datei lässt sich nicht stückweise lesen, oder die Folge ist zu kurz.
    case unsupportedAudio
    /// Die Stücke passten nicht sicher genug zu den Untertiteln.
    case notAligned
}

/// Schritt 2 der Reihenfolge, von der App eingesetzt. `provide` liefert die
/// Untertitel oder `nil`; `report` erfährt, wie der Abgleich ausging.
public struct TwinCaptionHook: Sendable {
    public let provide: @Sendable (Episode) async -> TwinCaptions?
    public let report: @Sendable (EpisodeID, TwinCaptions, TwinAlignmentOutcome) -> Void

    public init(provide: @escaping @Sendable (Episode) async -> TwinCaptions?,
                report: @escaping @Sendable (EpisodeID, TwinCaptions, TwinAlignmentOutcome) -> Void) {
        self.provide = provide
        self.report = report
    }
}

public actor ContentPipeline {

    private let store: LibraryStore
    private let mediaDirectory: URL
    private let downloader: MediaDownloader
    private let engine = TimedTranscriptionEngine()
    private let assembler = TranscriptAssembler()
    private let scorer = RelevanceScorer()
    private let checkpoints: TranscriptCheckpointStore
    private let onProgress: @Sendable (PipelineProgress) -> Void
    private let twin: TwinCaptionHook?
    /// Lädt im WLAN über die Sitzung des Systems, sonst `nil`.
    private let backgroundDownloads: BackgroundDownloadSession?

    /// Zwischenstände liegen neben dem Ordner der Audiodateien, nicht darin:
    /// dort zählt die App jede Datei als geladenen Ton.
    /// So weit darf ein Zwischenstand über die gemessene Länge der Datei
    /// hinausreichen, bevor er als Stand einer anderen Datei gilt.
    static let checkpointTolerance = MediaDuration(seconds: 2)

    /// Passt der Zwischenstand zur Länge der Datei? Ohne bekannte Länge ja.
    static func checkpoint(_ checkpoint: TranscriptCheckpoint, fits duration: MediaDuration?) -> Bool {
        guard let duration else { return true }
        return checkpoint.analyzedThrough.milliseconds
            <= duration.milliseconds + checkpointTolerance.milliseconds
    }

    public static func checkpointDirectory(besides mediaDirectory: URL) -> URL {
        mediaDirectory.deletingLastPathComponent()
            .appendingPathComponent("TranscriptCheckpoints", isDirectory: true)
    }

    public init(
        store: LibraryStore,
        mediaDirectory: URL,
        twin: TwinCaptionHook? = nil,
        backgroundDownloads: BackgroundDownloadSession? = nil,
        onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) {
        self.store = store
        self.mediaDirectory = mediaDirectory
        self.downloader = MediaDownloader(directory: mediaDirectory)
        self.checkpoints = TranscriptCheckpointStore(
            directory: Self.checkpointDirectory(besides: mediaDirectory))
        self.onProgress = onProgress
        self.twin = twin
        self.backgroundDownloads = backgroundDownloads
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
        // Sonst die Untertitel desselben Inhalts auf YouTube, falls die App
        // sie holen darf und sie sich sicher auf den Ton legen lassen.
        if let twin {
            onProgress(PipelineProgress(
                episodeID: episode.id, stage: .discovered,
                detail: String(localized: "sucht Untertitel auf YouTube", bundle: .module)))
            if let captions = await twin.provide(episode) {
                try Task.checkCancellation()
                let evidence: [Evidence]?
                do {
                    let outcome: TwinAlignmentOutcome
                    (evidence, outcome) = try await processTwinCaptions(
                        captions, episode: episode, audioURL: audioURL,
                        mediaVersionID: mediaVersionID, sourceID: sourceID, locale: locale)
                    twin.report(episode.id, captions, outcome)
                } catch {
                    // Ohne Sprachmodell oder Speicher scheitert die Folge ganz.
                    // Der nächste Versuch soll dafür nicht wieder Untertitel holen.
                    if !(error is CancellationError) { twin.report(episode.id, captions, .notAligned) }
                    throw error
                }
                if let evidence { return evidence }
            }
            try Task.checkCancellation()
        }
        // Liegt die Datei schon da, wird sie nicht ein zweites Mal geladen.
        let download: DownloadResult
        if let existing = await downloader.existing(mediaVersionID: mediaVersionID) {
            download = existing
        } else {
            download = try await downloader.download(
                from: audioURL, mediaVersionID: mediaVersionID, background: backgroundDownloads)
        }
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .mediaDownloaded,
            detail: download.duration?.shortDescription
        ))

        let mediaURL = mediaDirectory.appendingPathComponent(mediaVersionID.rawValue)
        var segments: [TranscriptSegment] = []
        var analyzedThrough = MediaTime.zero
        var startingAt = MediaTime.zero
        var batch: [(range: MediaTimeRange, text: String, isFinal: Bool)] = []

        // Ein früherer Lauf wurde abgebrochen: mit seinem Stand weiter, kurz
        // vor der Stelle, an der er endete.
        // Reicht der Stand über das Ende der Datei hinaus, liegt unter derselben
        // Adresse inzwischen eine andere Datei. Dann beginnt der Lauf neu.
        if let checkpoint = checkpoints.load(mediaVersionID: mediaVersionID, locale: locale.identifier),
           Self.checkpoint(checkpoint, fits: download.duration) {
            let resume = assembler.resumePoint(from: checkpoint)
            segments = resume.segments
            analyzedThrough = resume.analyzedThrough
            startingAt = resume.offset
        }

        let totalMs = download.duration?.milliseconds ?? 0
        var reportedFraction = -1.0
        let checkpointLocale = locale.identifier
        let saveCheckpoint = { [checkpoints] (segments: [TranscriptSegment], through: MediaTime) in
            guard through.milliseconds > 0 else { return }
            try? checkpoints.save(TranscriptCheckpoint(
                mediaVersionID: mediaVersionID, locale: checkpointLocale,
                segments: segments, analyzedThrough: through))
        }

        do {
            for try await result in try await engine.transcribeFile(
                at: mediaURL, mediaVersionID: mediaVersionID, locale: locale, startingAt: startingAt
            ) {
                guard result.isFinal, let range = result.range else { continue }
                batch.append((range: range, text: result.text, isFinal: true))
                if range.end > analyzedThrough { analyzedThrough = range.end }

                // Fein gemeldet, damit die Anzeige des Systems im Hintergrund
                // Fortschritt sieht. Ein Prozent reicht als Schritt.
                if totalMs > 0 {
                    let fraction = min(1, Double(analyzedThrough.milliseconds) / Double(totalMs))
                    if fraction - reportedFraction >= 0.01 {
                        reportedFraction = fraction
                        onProgress(PipelineProgress(
                            episodeID: episode.id, stage: .mediaDownloaded, fraction: fraction))
                    }
                }

                // In Schüben zusammenführen statt je Ergebnis: das hält die
                // Deduplizierung billig und schafft einen sicheren Punkt zum
                // Anhalten. Dort liegt auch der Zwischenstand.
                if batch.count >= 50 {
                    segments = assembler.merge(existing: segments, incoming: batch,
                                               mediaVersionID: mediaVersionID)
                    batch.removeAll(keepingCapacity: true)
                    saveCheckpoint(segments, analyzedThrough)
                    try Task.checkCancellation()
                }
            }
            // Ein abgebrochener Strom endet still. Ohne diese Prüfung sähe
            // das halbe Transkript wie ein fertiges aus.
            try Task.checkCancellation()
        } catch {
            // Was bis hierher erkannt ist, bleibt für den nächsten Lauf. Die
            // Erkennung hält sofort an, statt ohne Abnehmer weiterzurechnen.
            if !batch.isEmpty {
                segments = assembler.merge(existing: segments, incoming: batch,
                                           mediaVersionID: mediaVersionID)
            }
            saveCheckpoint(segments, analyzedThrough)
            await engine.cancel()
            throw error
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
        // Das Transkript steht. Ein Zwischenstand würde nur noch stören.
        checkpoints.remove([mediaVersionID])

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

    // MARK: Untertitel des YouTube-Zwillings

    /// Länge eines Stücks für den Abgleich.
    static let twinWindowLength: Int64 = 25_000
    /// Wo die ersten Stücke liegen, als Anteil der Folge.
    static let twinWindowPositions = [0.10, 0.50, 0.85]
    /// Ersatz, wenn ein Stück in Musik oder Werbung fiel.
    static let twinBackupPositions = [0.30, 0.70]
    /// Höchstens so viele Stücke je Folge, das Eingrenzen eingeschlossen.
    static let twinMaxWindows = 7

    /// Legt die Untertitel auf die Zeit der Audiodatei und speichert sie.
    ///
    /// Ein paar Stücke des Tons transkribiert das Gerät selbst, jedes wird in
    /// den Untertiteln gesucht (`CaptionAlignment`). Nur wenn mindestens zwei
    /// sicher passen und die Versätze zusammen Sinn ergeben, entsteht das
    /// Transkript, mit den Zeiten des Tons. Sonst `nil`, und die Folge wird
    /// wie bisher geladen und ganz transkribiert. Weiter oben landen nur ein
    /// Abbruch und Fehler, an denen auch die eigene Erkennung scheitern würde.
    private func processTwinCaptions(
        _ twin: TwinCaptions, episode: Episode, audioURL: URL,
        mediaVersionID: MediaVersionID, sourceID: SourceID, locale: Locale
    ) async throws -> ([Evidence]?, TwinAlignmentOutcome) {
        // Untertitel in einer anderen Sprache sind eine Übersetzung, kein Transkript.
        if let lang = twin.captions.lang, !lang.isEmpty,
           let wanted = locale.language.languageCode?.identifier,
           SupadataLanguage.base(lang) != SupadataLanguage.base(wanted) {
            return (nil, .languageMismatch)
        }
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .discovered,
            detail: String(localized: "gleicht Untertitel von YouTube ab", bundle: .module)))

        let cues = CaptionAnalysis.cues(from: twin.captions)
        let captionWords = CaptionAlignment.words(cues: cues)
        let local = await downloader.existing(mediaVersionID: mediaVersionID)

        let source: any AudioWindowSource
        do {
            if local != nil, let windows = LocalAudioWindows(
                fileURL: mediaDirectory.appendingPathComponent(mediaVersionID.rawValue)) {
                source = windows
            } else {
                source = try await RemoteMP3Windows.open(url: audioURL, declaredDuration: episode.declaredDuration)
            }
        } catch {
            try Task.checkCancellation()
            return (nil, .unsupportedAudio)
        }
        let total = source.duration.milliseconds
        guard total >= AudioTwinPlanner.minimumDuration.milliseconds else { return (nil, .unsupportedAudio) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinWindows-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var anchors: [AlignmentAnchor] = []
        var failed: [Int64] = []
        var used = 0
        let length = Self.twinWindowLength

        // Erst drei Stücke über die Folge verteilt. Passte eines davon, gibt
        // es Ersatz für solche, die in Musik oder Werbung fielen; passte
        // keines, ist das Video wohl nicht diese Folge. Wechselt der Versatz zwischen
        // zwei Stücken, etwa durch Werbung im MP3, grenzen weitere Stücke die
        // Stelle ein.
        var pending = Self.twinWindowPositions.map { Int64(Double(total) * $0) }
        var backups = Self.twinBackupPositions.map { Int64(Double(total) * $0) }
        while used < Self.twinMaxWindows {
            let requested: Int64
            if !pending.isEmpty {
                requested = pending.removeFirst()
            } else if anchors.count == 1, !backups.isEmpty {
                requested = backups.removeFirst()
            } else if let next = CaptionAlignment.nextProbe(anchors: anchors, failedProbes: failed) {
                requested = next - length / 2
            } else {
                break
            }
            let start = max(0, min(total - length, requested))
            used += 1
            do {
                if let anchor = try await alignWindow(
                    at: start, length: length, from: source, into: directory,
                    captionWords: captionWords, locale: locale) {
                    anchors.append(anchor)
                } else {
                    failed.append(start + length / 2)
                }
            } catch AudioWindowError.unsupported {
                return (nil, .unsupportedAudio)
            }
        }
        try Task.checkCancellation()

        guard case .success(let mapping) = CaptionAlignment.mapping(from: anchors),
              case .success(let shifted) = CaptionAlignment.shift(
                cues: cues, by: mapping, audioDuration: MediaDuration(milliseconds: total)) else {
            return (nil, .notAligned)
        }
        let transcript = CaptionTranscriptBuilder.transcript(
            from: shifted, mediaVersionID: mediaVersionID, locale: locale.identifier,
            origin: .youTubeCaptionsAligned)
        let evidence = assembler.evidence(
            from: transcript, episodeID: episode.id, sourceID: sourceID,
            ranges: CaptionAnalysis.passages(for: transcript))
        guard !evidence.isEmpty else { return (nil, .notAligned) }
        try Task.checkCancellation()

        // Wie beim Transkript des Podcasts: die Fassung ist die Audiodatei
        // aus dem Feed. Liegt sie schon auf dem Gerät, bleibt sie daran.
        try await store.save(
            transcript: transcript,
            media: MediaVersion(
                id: mediaVersionID,
                episodeID: episode.id,
                remoteURL: audioURL,
                localRelativePath: local?.localRelativePath,
                byteCount: local?.byteCount,
                contentHash: local?.contentHash,
                duration: local?.duration ?? MediaDuration(milliseconds: total),
                mimeType: local?.mimeType
            ),
            forEpisode: episode.id
        )
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .transcribed,
            detail: TranscriptOrigin.youTubeCaptionsAligned.sourceLabel))
        try await store.store(evidence: evidence)
        onProgress(PipelineProgress(
            episodeID: episode.id, stage: .evidenceExtracted,
            detail: String(AttributedString(
                localized: "^[\(evidence.count) Fundstelle](inflect: true)", bundle: .module).characters)
        ))
        return (evidence, .aligned(constant: mapping.isConstant, anchors: anchors.count))
    }

    /// Ein Stück holen, selbst transkribieren und in den Untertiteln suchen.
    /// `nil`, wenn es sich nicht holen oder nicht sicher zuordnen lässt.
    private func alignWindow(
        at start: Int64, length: Int64, from source: any AudioWindowSource, into directory: URL,
        captionWords: [AlignmentWord], locale: Locale
    ) async throws -> AlignmentAnchor? {
        do {
            let window = try await source.window(at: start, length: length, into: directory)
            defer { try? FileManager.default.removeItem(at: window.fileURL) }
            let words = try await transcribeWindow(window, locale: locale)
            return CaptionAlignment.match(window: words, captions: captionWords)?.anchor
        } catch AudioWindowError.unsupported {
            throw AudioWindowError.unsupported
        } catch let error as TranscriptionError {
            // Ohne Spracherkennung oder Sprachmodell scheiterte auch der
            // Weg über den ganzen Ton. Das soll die Folge sagen.
            switch error {
            case .speechUnavailableOnDevice, .localeNotSupported, .modelUnavailable: throw error
            default: return nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// Transkribiert ein Stück und gibt seine Wörter mit Zeiten in der Folge zurück.
    private func transcribeWindow(_ window: AudioWindow, locale: Locale) async throws -> [AlignmentWord] {
        // Eine eigene Erkennung je Stück; eine gebrauchte meldet sich erst
        // kurz nach dem Ende ihres Stroms frei.
        let engine = TimedTranscriptionEngine()
        var words: [AlignmentWord] = []
        let stream = try await engine.transcribeFile(
            at: window.fileURL, mediaVersionID: MediaVersionID(stable: window.fileURL.absoluteString),
            locale: locale)
        do {
            for try await result in stream {
                guard result.isFinal, let range = result.range else { continue }
                words += CaptionAlignment.words(
                    text: result.text, start: window.start + range.start.milliseconds,
                    end: window.start + range.end.milliseconds)
            }
            try Task.checkCancellation()
        } catch {
            await engine.cancel()
            throw error
        }
        return words.sorted { $0.time < $1.time }
    }

    /// Baut Kandidaten für eine persönliche Ausgabe.
    ///
    /// Reihenfolge: deterministische Vorauswahl, dann — sofern verfügbar —
    /// Modellbestätigung. Das Modell kann die Auswahl nur **verengen**, nie
    /// erweitern: es sieht ausschließlich, was die Vorauswahl zugelassen hat.
    /// Fällt es aus oder wählt es nichts, entsteht die Ausgabe trotzdem und
    /// ist als nur stichwortbasiert erkennbar.
    public func candidates(
        for feed: SmartPodcastFeed,
        profile: InterestProfile,
        availability: ModelStatus,
        titles: [EpisodeID: (source: String, episode: String, published: Date?)] = [:]
    ) async throws -> [SegmentCandidate] {

        let evidence = try await store.evidenceForAnalyzedEpisodes()
        guard !evidence.isEmpty else { return [] }

        // Über Kapitel-Tags; Folgen ohne Kapitel-Tag über Stichworte.
        var matches = ChapterTagRelevance.matches(
            evidence: evidence, chapterTags: try await store.allChapterTags(),
            profile: profile, scorer: scorer)
        let feedTopics = Set(feed.topicIDs)
        if !feedTopics.isEmpty {
            matches = matches.filter { feedTopics.contains($0.interestID) }
        }
        guard !matches.isEmpty else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })

        var confirmed: Set<EvidenceID>?
        if case .success = availability.resolve(.recommend) {
            // Treffer über Kapitel-Tags sind schon eingeordnet. Das Modell
            // prüft nur, was über Stichworte kam.
            let shortlist = matches.filter { !$0.isModelConfirmed }.compactMap { byID[$0.evidenceID] }
            // Eine leere Auswahl zählt wie keine Antwort. Die Anweisung an
            // das Modell erlaubt sie ausdrücklich, und sie kann von Anfrage
            // zu Anfrage anders ausfallen. Dann blieb etwa die erste Ausgabe
            // eines neuen Updates leer, obwohl Stichworte trafen, und erst
            // ein zweiter Versuch baute sie. Das Modell darf verengen,
            // aber nicht auf nichts.
            if !shortlist.isEmpty, let selection = try? await KnowledgeExtractor()
                .selectRelevant(from: shortlist, profile: profile, availability: availability),
               !selection.evidenceIDs.isEmpty {
                confirmed = Set(selection.evidenceIDs)
            }
        }

        return matches.compactMap { match -> SegmentCandidate? in
            guard let item = byID[match.evidenceID] else { return nil }
            if let confirmed, !match.isModelConfirmed, !confirmed.contains(match.evidenceID) { return nil }

            let stamped = RelevanceMatch(
                evidenceID: match.evidenceID, interestID: match.interestID,
                interestLabel: match.interestLabel, kind: match.kind,
                score: match.score, matchedTerms: match.matchedTerms,
                isModelConfirmed: match.isModelConfirmed || (confirmed?.contains(match.evidenceID) ?? false)
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

    /// Die Kapitel, aus denen ein Themen-Update wählt.
    ///
    /// Hat die Bibliothek Kapitel-Tags, zählen nur sie. Erst wenn es noch
    /// gar keine gibt, sucht `RelevanceScorer` über Stichworte, und das
    /// Modell darf dessen Treffer nur verengen. Die Grenze je Tag setzt
    /// hier niemand; sie greift im Publisher nach dem Hörzustand.
    ///
    /// `tags`: die Tags des Updates oder, ohne eigene, die gefolgten.
    /// Für bloße Zahlen reicht weniger: `titledSections: false` spart die
    /// Satzvektoren für die Titel abgeleiteter Abschnitte,
    /// `modelConfirmation: false` die Rückfrage beim Modell.
    public func editionChapters(
        tags: Set<InterestID>,
        profile: InterestProfile,
        availability: ModelStatus,
        titledSections: Bool = true,
        modelConfirmation: Bool = true,
        titles: [EpisodeID: EditionChapterBuilder.Titles] = [:]
    ) async throws -> [EditionChapter] {
        guard !tags.isEmpty else { return [] }
        let evidence = try await store.evidenceForAnalyzedEpisodes()
        guard !evidence.isEmpty else { return [] }
        let chapterTags = try await store.allChapterTags()

        var matches: [RelevanceMatch] = []
        var episodeIDs: Set<EpisodeID>
        if chapterTags.isEmpty {
            let unlimited = RelevanceScorer(threshold: scorer.threshold, maximumPerInterest: .max)
            matches = unlimited.score(evidence: evidence, profile: profile)
                .filter { tags.contains($0.interestID) }
            let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if modelConfirmation, case .success = availability.resolve(.recommend), !matches.isEmpty {
                let shortlist = matches.compactMap { byID[$0.evidenceID] }
                if let selection = try? await KnowledgeExtractor()
                    .selectRelevant(from: shortlist, profile: profile, availability: availability),
                   !selection.evidenceIDs.isEmpty {
                    let confirmed = Set(selection.evidenceIDs)
                    matches = matches.filter { confirmed.contains($0.evidenceID) }
                }
            }
            episodeIDs = Set(matches.compactMap { byID[$0.evidenceID]?.episodeID })
        } else {
            episodeIDs = Set(chapterTags.filter { tags.contains($0.interestID) }.map(\.episodeID))
        }
        guard !episodeIDs.isEmpty else { return [] }

        let ordered = episodeIDs.sorted { $0.rawValue < $1.rawValue }
        let episodes = try await store.episodes(ids: ordered)
        let facts = try await store.facts(forEpisodes: episodeIDs)
        let unmeasured: ChapterSections.JumpMeasure = { _ in nil }
        let jumps = titledSections ? ChapterSections.embeddingJumps : unmeasured
        return EditionChapterBuilder.build(
            evidence: evidence.filter { episodeIDs.contains($0.episodeID) },
            chapterTags: chapterTags.filter { episodeIDs.contains($0.episodeID) },
            episodes: Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            facts: facts, titles: titles, tags: tags,
            terms: EditionChapterBuilder.terms(for: profile.interests, tags: tags),
            keywordMatches: matches,
            jumps: jumps)
    }
}
#endif
