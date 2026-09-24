//
//  PersonalEpisodePublisher.swift
//  PodcastAISmartFeeds
//
//  Der Weg von „es gibt neues passendes Material“ zu einer persönlichen
//  Ausgabe. Reihenfolge ist verbindlich:
//
//    Scope prüfen → Belege wählen → auf Kapitel einrasten → Hörzustand
//    abziehen → Budget anwenden → Abspielfolge → unveränderliches Manifest
//    bilden → Shownotes → veröffentlichen
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

/// Die Kapitelmarken einer Originalfolge.
///
/// Ein Kapitel reicht bis zum nächsten, das letzte bis zum Ende der Folge,
/// sofern ihre Länge bekannt ist. Liegt eine passende Stelle in einem
/// Kapitel, spielt die Ausgabe das ganze Kapitel: es beginnt und endet dort,
/// wo der Podcast selbst schneidet.
public struct EpisodeChapters: Sendable, Hashable {

    /// Kapitelanfänge, aufsteigend und ohne Doppelte.
    public let starts: [MediaTime]
    /// Länge der Folge. Ohne sie hat das letzte Kapitel kein Ende.
    public let duration: MediaDuration?

    public init(chapters: [Chapter], duration: MediaDuration? = nil) {
        self.starts = Array(Set(chapters.map(\.start))).sorted()
        self.duration = duration
    }

    /// Von der Kapitelgrenze vor der Stelle bis zur Kapitelgrenze nach ihr.
    /// Reicht die Stelle über eine Grenze, umfasst der Bereich beide Kapitel.
    /// `nil`, wenn die Stelle vor dem ersten Kapitel beginnt oder das Ende
    /// des letzten Kapitels unbekannt ist.
    public func span(covering range: MediaTimeRange) -> MediaTimeRange? {
        guard let first = starts.lastIndex(where: { $0 <= range.start }) else { return nil }
        // Endet die Stelle genau auf einer Grenze, gehört sie zum Kapitel davor.
        let last = max(first, starts.lastIndex(where: { $0 < range.end }) ?? first)
        let end: MediaTime
        if last + 1 < starts.count {
            end = starts[last + 1]
        } else if let duration, duration.milliseconds > starts[last].milliseconds {
            end = MediaTime(milliseconds: duration.milliseconds)
        } else {
            return nil
        }
        return MediaTimeRange(start: starts[first], end: end)
    }
}

public struct PublisherOptions: Sendable {
    /// Kontext vor dem eigentlich Neuen. Macht einen Einstieg verständlich,
    /// zählt aber nicht als neuer Inhalt.
    public var contextLeadIn: MediaDuration
    /// Kürzeste Länge, die ein Abschnitt haben muss.
    public var minimumSegmentDuration: MediaDuration
    /// Längster Einzelabschnitt. Ein längeres Kapitel wird nicht ganz
    /// gespielt, dann bleibt es bei der passenden Stelle.
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
    ///
    /// `chapters`: die Kapitelmarken der Originalfolgen, soweit bekannt.
    /// Liegt eine Stelle in einem Kapitel, das nicht länger als
    /// `maximumSegmentDuration` ist und allein ins Zeitbudget des Feeds
    /// passt, spielt die Ausgabe das ganze Kapitel.
    public func makeEdition(
        feed: SmartPodcastFeed,
        candidates: [SegmentCandidate],
        ledger: ListeningLedger,
        chapters: [EpisodeID: EpisodeChapters] = [:],
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

        // 1. Auf Kapitel einrasten und den Hörzustand anwenden: nur echt
        //    Ungehörtes bleibt Kandidat.
        let unheard = resolveUnheard(
            candidates, ledger: ledger, chapters: chapters, feed: feed, options: options)
        guard !unheard.isEmpty else {
            return .noNewMaterial(candidateCount: candidates.count)
        }

        // 2. Identität des Kandidatenlaufs. Bewusst aus den **Kerninhalten**
        //    gebildet und reihenfolgeunabhängig: ein zweiter Refresh mit
        //    denselben Stellen erzeugt denselben Schlüssel, auch wenn die
        //    Reihenfolge der Kandidaten anders hereinkam.
        //
        //    Die Kerne kommen aus den Stellen selbst, nicht aus ihren
        //    Kapiteln. Kapitelmarken lädt die App nach und nach aus dem Netz
        //    und hält sie nur im Speicher. Hinge der Schlüssel an ihnen,
        //    bekäme derselbe Stand mit jedem neu geladenen Kapitel einen
        //    neuen Schlüssel und damit eine zweite Ausgabe.
        let passages = chapters.isEmpty ? unheard : resolveUnheard(
            candidates, ledger: ledger, chapters: [:], feed: feed, options: options)
        let batchKey = Self.batchKey(for: passages)
        if existingBatchKeys.contains(batchKey) {
            return .alreadyPublished(PersonalEpisodeID(stable: batchKey))
        }
        // Frühere Ausgaben tragen den Schlüssel ihrer Kapitel. Gleicht er,
        // ist es dieselbe Ausgabe.
        let chapterKey = Self.batchKey(for: unheard)
        if existingBatchKeys.contains(chapterKey) {
            return .alreadyPublished(PersonalEpisodeID(stable: chapterKey))
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
            if lhs.relevanceScore != rhs.relevanceScore {
                return lhs.relevanceScore > rhs.relevanceScore
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

        // 5. Abspielfolge: Folgen nach Relevanz, ihre Abschnitte am Stück und
        //    in der Reihenfolge des Originals.
        let ordered = Self.playbackOrder(selected)

        // 6. Virtuelle Zeitachse aufbauen und Manifest bilden.
        let segments = buildSegments(ordered, options: options)
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

    /// Schlüssel eines Kandidatenlaufs aus Fassung und Kern jedes Abschnitts.
    static func batchKey(for items: [UnheardCandidate]) -> String {
        StableDigest.hex(ofUnordered: items.map {
            "\($0.candidate.evidence.mediaVersionID.rawValue):\($0.core.start.milliseconds)-\($0.core.end.milliseconds)"
        })
    }

    // MARK: - Ungehörtes auflösen

    struct UnheardCandidate {
        /// Der tragende Kandidat. Titel, Grund und Fassung kommen von ihm.
        var candidate: SegmentCandidate
        /// Alle Belege, die in diesem Abschnitt erklingen, der tragende zuerst.
        var evidenceIDs: [EvidenceID]
        var topicIDs: [InterestID]
        /// Der beste Wert unter den Belegen des Abschnitts.
        var relevanceScore: Double
        /// Das tatsächlich Neue.
        let core: MediaTimeRange
        /// Was abgespielt wird, inklusive Kontextvorlauf.
        let playback: MediaTimeRange
        var hasContextReplay: Bool { playback.start < core.start }

        init(candidate: SegmentCandidate, core: MediaTimeRange, playback: MediaTimeRange) {
            self.candidate = candidate
            self.evidenceIDs = [candidate.evidence.id]
            self.topicIDs = candidate.topicIDs
            self.relevanceScore = candidate.relevanceScore
            self.core = core
            self.playback = playback
        }

        /// Nimmt einen weiteren Beleg auf, der in diesem Abschnitt schon
        /// erklingt. Der relevantere wird zum tragenden.
        mutating func absorb(_ other: SegmentCandidate) {
            for topic in other.topicIDs where !topicIDs.contains(topic) { topicIDs.append(topic) }
            evidenceIDs.removeAll { $0 == other.evidence.id }
            if other.relevanceScore > relevanceScore {
                relevanceScore = other.relevanceScore
                candidate = other
                evidenceIDs.insert(other.evidence.id, at: 0)
            } else {
                evidenceIDs.append(other.evidence.id)
            }
        }
    }

    private func resolveUnheard(
        _ candidates: [SegmentCandidate],
        ledger: ListeningLedger,
        chapters: [EpisodeID: EpisodeChapters],
        feed: SmartPodcastFeed,
        options: PublisherOptions
    ) -> [UnheardCandidate] {

        var result: [UnheardCandidate] = []
        // Innerhalb eines Laufs bereits belegte Bereiche — verhindert, dass
        // zwei Belege derselben Stelle zweimal in dieselbe Ausgabe geraten.
        var reserved: [MediaVersionID: IntervalSet] = [:]

        // Ein Kapitel, das allein nicht ins Zeitbudget passt, fiele beim
        // Budget ganz heraus, denn gekürzt wird dort nicht. Dann spielt die
        // Ausgabe nur die Stelle.
        func fits(_ chapter: MediaTimeRange) -> Bool {
            guard chapter.duration <= options.maximumSegmentDuration else { return false }
            guard let budget = feed.editionMode.budget else { return true }
            return chapter.duration.listeningDuration(atRate: options.playbackRate) <= budget
        }

        for candidate in candidates {
            guard let range = candidate.evidence.range, !range.isEmpty else { continue }
            let mediaID = candidate.evidence.mediaVersionID

            // „Nur noch nicht begonnene Folgen“: eine angefangene Folge fällt
            // komplett heraus, auch wenn Teile davon ungehört sind.
            if feed.unheardFilter == .neverStartedEpisodes,
               !ledger.heard(in: mediaID).isEmpty {
                continue
            }

            // Das Neue an der Stelle selbst. Ist sie schon gehört, holt auch
            // ihr Kapitel sie nicht zurück.
            let unheardPassage = ledger.unheardPortion(
                of: range, in: mediaID, minimumFragment: options.minimumSegmentDuration
            )
            guard let passage = unheardPassage.ranges.max(by: { $0.duration < $1.duration }) else { continue }

            // Erklingt die Stelle schon in einem Abschnitt dieses Laufs, etwa
            // im selben Kapitel, kommt ihr Beleg dorthin, statt zu verschwinden.
            if let index = result.firstIndex(where: {
                $0.candidate.evidence.mediaVersionID == mediaID
                    && $0.core.start <= passage.start && passage.end <= $0.core.end
            }) {
                result[index].absorb(candidate)
                continue
            }

            func unreserved(_ set: IntervalSet) -> IntervalSet {
                guard let alreadyReserved = reserved[mediaID] else { return set }
                return set.subtracting(alreadyReserved)
                    .droppingFragments(shorterThan: options.minimumSegmentDuration)
            }

            // Auf das Kapitel des Originals einrasten, wenn es eines gibt und
            // es nicht zu lang ist. Sonst bleibt es bei der Stelle.
            let chapter = chapters[candidate.episodeID]?.span(covering: passage)
                .flatMap { fits($0) ? $0 : nil }
            var core: MediaTimeRange?
            var floor: Int64 = 0
            if let chapter {
                let pieces = unreserved(ledger.unheardPortion(
                    of: chapter, in: mediaID, minimumFragment: options.minimumSegmentDuration))
                if let piece = pieces.ranges.first(where: { $0.overlaps(passage) }) {
                    core = piece
                    floor = chapter.start.milliseconds
                }
            }
            if core == nil {
                core = unreserved(unheardPassage).ranges
                    .max(by: { $0.duration < $1.duration })?
                    .clamped(toDuration: options.maximumSegmentDuration)
            }
            guard let core else { continue }

            // Kontextvorlauf: vor dem Neuen, bewusst auch schon Gehörtes.
            // Beginnt der Abschnitt am Kapitelanfang, braucht er keinen, und
            // er reicht nie ins Kapitel davor.
            let playback = MediaTimeRange(
                start: MediaTime(milliseconds: max(floor, core.start.milliseconds
                                                   - options.contextLeadIn.milliseconds)),
                end: core.end
            )

            reserved[mediaID, default: IntervalSet()].insert(core)
            result.append(UnheardCandidate(candidate: candidate, core: core, playback: playback))
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

    // MARK: - Abspielfolge

    /// Folgen nach Relevanz, ihre Abschnitte am Stück und in der Zeitfolge
    /// des Originals. Wer eine Folge hört, springt darin nicht zurück, und
    /// zwischen zwei Stellen derselben Folge schiebt sich keine andere.
    ///
    /// `selected` kommt nach Relevanz sortiert. Eine Folge steht deshalb
    /// dort, wo ihr relevantester Abschnitt stand.
    static func playbackOrder(_ selected: [UnheardCandidate]) -> [UnheardCandidate] {
        var order: [EpisodeID] = []
        var groups: [EpisodeID: [UnheardCandidate]] = [:]
        for item in selected {
            let key = item.candidate.episodeID
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.flatMap { key in
            (groups[key] ?? []).sorted { lhs, rhs in
                if lhs.core.start != rhs.core.start { return lhs.core.start < rhs.core.start }
                return lhs.candidate.evidence.mediaVersionID.rawValue
                    < rhs.candidate.evidence.mediaVersionID.rawValue
            }
        }
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
                evidenceIDs: item.evidenceIDs,
                coreRange: item.core,
                playbackRange: item.playback,
                virtualRange: virtual,
                reason: item.candidate.reason,
                topicIDs: item.topicIDs,
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
            return segment.moved(to: virtual)
        }

        // Die Übersicht folgt: Kapitel ohne übrigen Abschnitt fallen weg,
        // die übrigen rücken mit ihren Abschnitten nach vorn.
        let starts = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.virtualRange.start) })
        let overview = episode.overviewEntries.compactMap { entry -> EditionOverviewEntry? in
            let ids = entry.segmentIDs.filter { starts[$0] != nil }
            guard let first = ids.first, let start = starts[first] else { return nil }
            return entry.replacing(segmentIDs: ids, virtualStart: start, tagIDs: entry.tagIDs)
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
            coverAssetID: episode.coverAssetID, coverage: coverage,
            part: episode.part, overviewEntries: overview
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
