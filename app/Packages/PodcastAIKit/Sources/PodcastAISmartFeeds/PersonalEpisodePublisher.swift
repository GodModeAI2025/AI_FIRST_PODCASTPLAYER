//
//  PersonalEpisodePublisher.swift
//  PodcastAISmartFeeds
//
//  Der Weg von „es gibt neues passendes Material“ zu einer persönlichen
//  Ausgabe. Reihenfolge ist verbindlich:
//
//    Scope prüfen → Belege wählen → Hörzustand abziehen → Budget anwenden
//    → unveränderliches Manifest bilden → Shownotes → veröffentlichen
//
//  Die Veröffentlichung startet **nie** Ton. Eine neue Ausgabe ist ein
//  Zustand, kein Ereignis mit Audio.
//

import Foundation
import PodcastAICore

/// Ein Kandidat für eine persönliche Ausgabe, bevor der Hörzustand angewendet wird.
public struct SegmentCandidate: Sendable, Hashable {

    public let evidence: Evidence
    public let episodeID: EpisodeID
    public let sourceID: SourceID
    public let sourceTitle: String
    public let episodeTitle: String
    public let originalPublishedAt: Date?
    public let transcriptRevision: Revision

    /// Welche Interessen dieser Kandidat trifft.
    public let topicIDs: [InterestID]
    /// Warum er relevant ist — wird wörtlich in die Shownotes übernommen.
    public let reason: String
    /// Rangfolge: höher ist relevanter. Entscheidet, was ins Budget kommt.
    public let relevanceScore: Double
    /// Ist die Quelle vollständig analysiert?
    public let sourceFullyAnalyzed: Bool

    public init(
        evidence: Evidence, episodeID: EpisodeID, sourceID: SourceID,
        sourceTitle: String, episodeTitle: String, originalPublishedAt: Date?,
        transcriptRevision: Revision, topicIDs: [InterestID], reason: String,
        relevanceScore: Double, sourceFullyAnalyzed: Bool = true
    ) {
        self.evidence = evidence; self.episodeID = episodeID; self.sourceID = sourceID
        self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.originalPublishedAt = originalPublishedAt
        self.transcriptRevision = transcriptRevision; self.topicIDs = topicIDs
        self.reason = reason; self.relevanceScore = relevanceScore
        self.sourceFullyAnalyzed = sourceFullyAnalyzed
    }
}

public struct PublisherOptions: Sendable {
    /// Kontext vor dem eigentlich Neuen. Macht einen Einstieg verständlich,
    /// zählt aber nicht als neuer Inhalt.
    public var contextLeadIn: MediaDuration
    /// Kürzeste Länge, die ein Abschnitt haben muss.
    public var minimumSegmentDuration: MediaDuration
    /// Längster Einzelabschnitt.
    public var maximumSegmentDuration: MediaDuration
    /// Hörbare Pause zwischen zwei Abschnitten, in der virtuellen Zeitachse.
    public var transition: MediaDuration
    public var playbackRate: Double

    public init(
        contextLeadIn: MediaDuration = MediaDuration(seconds: 6),
        minimumSegmentDuration: MediaDuration = MediaDuration(seconds: 25),
        maximumSegmentDuration: MediaDuration = MediaDuration(minutes: 10),
        transition: MediaDuration = MediaDuration(milliseconds: 800),
        playbackRate: Double = 1.0
    ) {
        self.contextLeadIn = contextLeadIn
        self.minimumSegmentDuration = minimumSegmentDuration
        self.maximumSegmentDuration = maximumSegmentDuration
        self.transition = transition
        self.playbackRate = playbackRate
    }
}

public enum PublicationOutcome: Sendable {
    case published(PersonalEpisode)
    /// Nichts Neues. Ein gültiges Ergebnis, kein Fehler — und ausdrücklich
    /// ein eigener Zustand statt einer leeren Ausgabe.
    case noNewMaterial(candidateCount: Int)
    /// Material vorhanden, aber unter der Schwelle der Veröffentlichungsregel.
    case belowThreshold(available: MediaDuration, required: MediaDuration)
    /// Diese Ausgabe existiert bereits — derselbe Kandidatenlauf.
    case alreadyPublished(PersonalEpisodeID)
}

public struct PersonalEpisodePublisher: Sendable {

    public init() {}

    /// Baut eine Ausgabe aus Kandidaten und dem gemeinsamen Hörzustand.
    ///
    /// Rein funktional: kein Store, kein Netzwerk, keine Nebenwirkung. Damit
    /// ist die Regel „zweimal derselbe Refresh ergibt eine Ausgabe“ testbar,
    /// statt von Transaktionsverhalten abzuhängen.
    ///
    /// `requestedByUser`: jemand hat ausdrücklich um eine Ausgabe gebeten.
    /// Dann gilt die Mindestmenge der automatischen Regel nicht. Sie soll
    /// verhindern, dass die App von selbst Mini-Ausgaben veröffentlicht,
    /// nicht, dass man drei Minuten Material hören kann, wenn man sie will.
    public func makeEdition(
        feed: SmartPodcastFeed,
        candidates: [SegmentCandidate],
        ledger: ListeningLedger,
        existingBatchKeys: Set<String> = [],
        requestedByUser: Bool = false,
        options: PublisherOptions = PublisherOptions(),
        now: Date = Date()
    ) -> PublicationOutcome {

        // 0. Scope: ein Feed mit ausgewählten Quellen sieht nur diese.
        let allowedSources = Set(feed.restrictedToSourceIDs)
        let candidates = allowedSources.isEmpty
            ? candidates
            : candidates.filter { allowedSources.contains($0.sourceID) }

        // 1. Hörzustand anwenden: nur echt Ungehörtes bleibt Kandidat.
        let unheard = resolveUnheard(candidates, ledger: ledger, feed: feed, options: options)
        guard !unheard.isEmpty else {
            return .noNewMaterial(candidateCount: candidates.count)
        }

        // 2. Identität des Kandidatenlaufs. Bewusst aus den **Kerninhalten**
        //    gebildet und reihenfolgeunabhängig: ein zweiter Refresh mit
        //    denselben Stellen erzeugt denselben Schlüssel, auch wenn die
        //    Reihenfolge der Kandidaten anders hereinkam.
        let batchKey = StableDigest.hex(ofUnordered: unheard.map {
            "\($0.candidate.evidence.mediaVersionID.rawValue):\($0.core.start.milliseconds)-\($0.core.end.milliseconds)"
        })
        if existingBatchKeys.contains(batchKey) {
            return .alreadyPublished(PersonalEpisodeID(stable: batchKey))
        }

        // 3. Schwelle der Veröffentlichungsregel prüfen.
        let availableCore = MediaDuration(
            milliseconds: unheard.reduce(0) { $0 + $1.core.duration.milliseconds }
        )
        let required = feed.publicationPolicy.minimumMaterial
        if !requestedByUser, feed.publicationPolicy.isAutomatic, availableCore < required {
            return .belowThreshold(available: availableCore, required: required)
        }

        // 4. Ranking und Budget. Bei gleicher Relevanz gewinnt das ältere
        //    Original — sonst verschwinden ältere Inhalte dauerhaft hinter
        //    ständig nachrückenden neuen.
        let ranked = unheard.sorted { lhs, rhs in
            if lhs.candidate.relevanceScore != rhs.candidate.relevanceScore {
                return lhs.candidate.relevanceScore > rhs.candidate.relevanceScore
            }
            let l = lhs.candidate.originalPublishedAt ?? .distantPast
            let r = rhs.candidate.originalPublishedAt ?? .distantPast
            if l != r { return l < r }
            // Letzter Tiebreak für Determinismus.
            return lhs.candidate.evidence.id.rawValue < rhs.candidate.evidence.id.rawValue
        }

        let (selected, remaining) = applyBudget(ranked, mode: feed.editionMode, options: options)
        guard !selected.isEmpty else {
            return .belowThreshold(available: availableCore, required: required)
        }

        // 5. Virtuelle Zeitachse aufbauen und Manifest bilden.
        let segments = buildSegments(selected, options: options)
        let shownotes = ShownotesBuilder().build(from: segments)

        let coverage = EditionCoverage(
            candidateCount: unheard.count,
            includedCount: selected.count,
            remaining: remaining,
            partiallyAnalyzedSourceIDs: Array(Set(
                unheard.filter { !$0.candidate.sourceFullyAnalyzed }.map(\.candidate.sourceID)
            )).sorted { $0.rawValue < $1.rawValue }
        )

        let episode = PersonalEpisode(
            id: PersonalEpisodeID(stable: batchKey),
            feedID: feed.id,
            policyRevision: feed.policyRevision,
            batchKey: batchKey,
            title: EditionTitleBuilder().title(for: feed, segments: segments, at: now),
            subtitle: EditionTitleBuilder().subtitle(for: segments, coverage: coverage),
            publishedAt: now,
            segments: segments,
            shownotes: shownotes,
            coverAssetID: feed.confirmedCoverAssetID,
            coverage: coverage
        )
        return .published(episode)
    }

    // MARK: - Ungehörtes auflösen

    struct UnheardCandidate {
        let candidate: SegmentCandidate
        /// Das tatsächlich Neue.
        let core: MediaTimeRange
        /// Was abgespielt wird, inklusive Kontextvorlauf.
        let playback: MediaTimeRange
        var hasContextReplay: Bool { playback.start < core.start }
    }

    private func resolveUnheard(
        _ candidates: [SegmentCandidate],
        ledger: ListeningLedger,
        feed: SmartPodcastFeed,
        options: PublisherOptions
    ) -> [UnheardCandidate] {

        var result: [UnheardCandidate] = []
        // Innerhalb eines Laufs bereits belegte Bereiche — verhindert, dass
        // zwei Belege derselben Stelle zweimal in dieselbe Ausgabe geraten.
        var reserved: [MediaVersionID: IntervalSet] = [:]

        for candidate in candidates {
            guard let range = candidate.evidence.range, !range.isEmpty else { continue }
            let mediaID = candidate.evidence.mediaVersionID

            // „Nur noch nicht begonnene Folgen“: eine angefangene Folge fällt
            // komplett heraus, auch wenn Teile davon ungehört sind.
            if feed.unheardFilter == .neverStartedEpisodes,
               !ledger.heard(in: mediaID).isEmpty {
                continue
            }

            var available = ledger.unheardPortion(
                of: range, in: mediaID, minimumFragment: options.minimumSegmentDuration
            )
            if let alreadyReserved = reserved[mediaID] {
                available = available.subtracting(alreadyReserved)
                    .droppingFragments(shorterThan: options.minimumSegmentDuration)
            }
            guard let core = available.ranges.max(by: { $0.duration < $1.duration }) else { continue }

            let clampedCore = core.clamped(toDuration: options.maximumSegmentDuration)
            // Kontextvorlauf: vor dem Neuen, bewusst auch schon Gehörtes.
            let playback = MediaTimeRange(
                start: MediaTime(milliseconds: max(0, clampedCore.start.milliseconds
                                                   - options.contextLeadIn.milliseconds)),
                end: clampedCore.end
            )

            reserved[mediaID, default: IntervalSet()].insert(clampedCore)
            result.append(UnheardCandidate(candidate: candidate, core: clampedCore, playback: playback))
        }
        return result
    }

    // MARK: - Budget

    private func applyBudget(
        _ ranked: [UnheardCandidate],
        mode: EditionMode,
        options: PublisherOptions
    ) -> ([UnheardCandidate], MediaDuration) {

        guard let budget = mode.budget else {
            return (ranked, .zero)
        }

        var selected: [UnheardCandidate] = []
        var used: Int64 = 0
        var leftOver: Int64 = 0

        for item in ranked {
            let listening = item.playback.duration
                .listeningDuration(atRate: options.playbackRate).milliseconds
            let transition = selected.isEmpty ? 0 : options.transition.milliseconds

            if used + transition + listening <= budget.milliseconds {
                used += transition + listening
                selected.append(item)
            } else {
                // Nicht kürzen: eine halbe Aussage ist schlechter als keine.
                // Der Rest bleibt sichtbar für die nächste Ausgabe.
                leftOver += item.core.duration.milliseconds
            }
        }
        return (selected, MediaDuration(milliseconds: leftOver))
    }

    // MARK: - Manifest

    private func buildSegments(
        _ selected: [UnheardCandidate],
        options: PublisherOptions
    ) -> [PersonalEpisodeSegment] {

        var segments: [PersonalEpisodeSegment] = []
        var cursor: Int64 = 0

        for item in selected {
            let playbackLength = item.playback.duration.milliseconds
            let virtual = MediaTimeRange(
                start: MediaTime(milliseconds: cursor),
                end: MediaTime(milliseconds: cursor + playbackLength)
            )
            cursor += playbackLength + options.transition.milliseconds

            segments.append(PersonalEpisodeSegment(
                id: TranscriptSegmentIDFactory.id(for: item),
                episodeID: item.candidate.episodeID,
                mediaVersionID: item.candidate.evidence.mediaVersionID,
                transcriptRevision: item.candidate.transcriptRevision,
                evidenceIDs: [item.candidate.evidence.id],
                coreRange: item.core,
                playbackRange: item.playback,
                virtualRange: virtual,
                reason: item.candidate.reason,
                topicIDs: item.candidate.topicIDs,
                contextReplay: item.hasContextReplay,
                sourceID: item.candidate.sourceID,
                sourceTitle: item.candidate.sourceTitle,
                episodeTitle: item.candidate.episodeTitle,
                originalPublishedAt: item.candidate.originalPublishedAt
            ))
        }
        return segments
    }
}

// MARK: - Nach dem Löschen

extension PersonalEpisodePublisher {

    /// Nimmt Abschnitte aus einer veröffentlichten Ausgabe.
    ///
    /// Die einzige Ausnahme von „unveränderlich“: wird eine Folge gelöscht
    /// oder ihre Quelle abbestellt, verschwindet auch, was aus ihr in eine
    /// Ausgabe geraten ist. Die übrigen Abschnitte rücken in der Zeitachse
    /// zusammen, Kapitel und Untertitel entstehen neu. Kennung und
    /// Schlüssel des Laufs bleiben, damit der Speicher die Zeile ersetzt
    /// statt eine zweite anzulegen.
    ///
    /// Gibt `nil` zurück, wenn kein Abschnitt übrig bleibt, und die Ausgabe
    /// unverändert, wenn keiner betroffen ist.
    public func removingSegments(
        from episode: PersonalEpisode,
        options: PublisherOptions = PublisherOptions(),
        where shouldRemove: (PersonalEpisodeSegment) -> Bool
    ) -> PersonalEpisode? {
        let kept = episode.segments.filter { !shouldRemove($0) }
        guard kept.count != episode.segments.count else { return episode }
        guard !kept.isEmpty else { return nil }

        var cursor: Int64 = 0
        let segments = kept.map { segment -> PersonalEpisodeSegment in
            let length = segment.playbackRange.duration.milliseconds
            let virtual = MediaTimeRange(
                start: MediaTime(milliseconds: cursor),
                end: MediaTime(milliseconds: cursor + length)
            )
            cursor += length + options.transition.milliseconds
            return PersonalEpisodeSegment(
                id: segment.id, episodeID: segment.episodeID,
                mediaVersionID: segment.mediaVersionID,
                transcriptRevision: segment.transcriptRevision,
                evidenceIDs: segment.evidenceIDs,
                coreRange: segment.coreRange, playbackRange: segment.playbackRange,
                virtualRange: virtual, reason: segment.reason, topicIDs: segment.topicIDs,
                contextReplay: segment.contextReplay, sourceID: segment.sourceID,
                sourceTitle: segment.sourceTitle, episodeTitle: segment.episodeTitle,
                originalPublishedAt: segment.originalPublishedAt
            )
        }

        let removedCount = episode.segments.count - kept.count
        let liveSources = Set(segments.map(\.sourceID))
        let coverage = EditionCoverage(
            candidateCount: max(segments.count, episode.coverage.candidateCount - removedCount),
            includedCount: segments.count,
            remaining: episode.coverage.remaining,
            partiallyAnalyzedSourceIDs: episode.coverage.partiallyAnalyzedSourceIDs
                .filter { liveSources.contains($0) }
        )

        var pruned = PersonalEpisode(
            id: episode.id, feedID: episode.feedID,
            revision: episode.revision.next(), policyRevision: episode.policyRevision,
            batchKey: episode.batchKey, title: episode.title,
            subtitle: EditionTitleBuilder().subtitle(for: segments, coverage: coverage),
            publishedAt: episode.publishedAt, publicationState: episode.publicationState,
            segments: segments, shownotes: ShownotesBuilder().build(from: segments),
            coverAssetID: episode.coverAssetID, coverage: coverage
        )
        pruned.consumptionState = episode.consumptionState
        return pruned
    }
}

extension PersonalEpisode {

    /// Welcher Anteil des Neuen in dieser Ausgabe schon gehört ist, egal ob
    /// in der Ausgabe selbst oder in der Originalfolge. Der Kontextvorlauf
    /// zählt nicht mit, er war nie neu.
    public func heardFraction(in ledger: ListeningLedger) -> Double {
        var total: Int64 = 0
        var heard: Int64 = 0
        for segment in segments {
            let length = segment.coreRange.duration.milliseconds
            guard length > 0 else { continue }
            total += length
            let covered = ledger.heard(in: segment.mediaVersionID).coverage(of: segment.coreRange)
            heard += Int64((Double(length) * covered).rounded())
        }
        guard total > 0 else { return 0 }
        return Double(heard) / Double(total)
    }
}

enum TranscriptSegmentIDFactory {
    static func id(for item: PersonalEpisodePublisher.UnheardCandidate) -> SegmentID {
        SegmentID(stable: "\(item.candidate.evidence.mediaVersionID.rawValue)|"
                  + "\(item.core.start.milliseconds)|\(item.core.end.milliseconds)")
    }
}
