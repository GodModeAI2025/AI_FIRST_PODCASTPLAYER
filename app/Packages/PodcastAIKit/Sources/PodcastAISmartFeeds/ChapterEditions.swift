//
//  ChapterEditions.swift
//  PodcastAISmartFeeds
//
//  Seit 0.11 entstehen Themen-Updates aus Kapiteln, nicht aus einzelnen
//  Stellen. Ein Kapitel passt, wenn es eines der Tags des Updates trägt
//  oder, im Modus „alle“, jedes davon. Die Reihenfolge ist verbindlich:
//
//    Eingrenzen → Tags prüfen → Veröffentlichtes abziehen → Gehörtes
//    abziehen → Grenze je Tag → Schlüssel und Schwelle → schneiden →
//    auf Teile verteilen → Manifest, Übersicht und Shownotes je Teil
//
//  Zeiten, Schnitte und Teile bestimmt nur dieser Code (Regel 3). Ein Modell
//  hat hier nichts zu sagen, die Tags der Kapitel stehen schon fest.
//  Veröffentlichen startet nie Ton (Regel 1).
//

import Foundation
import OSLog
import PodcastAICore
import PodcastAIKnowledge

/// Ein Kapitel des Originals als Baustein eines Themen-Updates: ein Kapitel
/// aus dem Feed oder ein abgeleiteter Abschnitt.
public struct EditionChapter: Sendable, Hashable {
    public let episodeID: EpisodeID
    public let mediaVersionID: MediaVersionID
    public let sourceID: SourceID
    public let sourceTitle: String
    public let episodeTitle: String
    /// Datum der Originalfolge. Die neueste Quelle kommt zuerst.
    public let originalPublishedAt: Date?
    public let transcriptRevision: Revision
    public let range: MediaTimeRange
    /// Titel des Kapitels, bei abgeleiteten Abschnitten „Abschnitt 3“.
    public let title: String?
    /// Alle Tags, die das Kapitel trägt.
    public let tagIDs: Set<InterestID>
    /// Die Belege im Kapitel, nach Anfang geordnet.
    public let passages: [Evidence]
    /// Welche Belege ein Tag wörtlich treffen. Daraus schneidet der Code,
    /// wenn das Kapitel nicht ganz in einen Teil passt.
    public let passageHits: [EvidenceID: Set<InterestID>]
    /// Die Zeitbereiche der Fakten im Kapitel, eine je Aussage.
    public let statements: [MediaTimeRange]
    public let sourceFullyAnalyzed: Bool

    public init(
        episodeID: EpisodeID, mediaVersionID: MediaVersionID, sourceID: SourceID,
        sourceTitle: String, episodeTitle: String, originalPublishedAt: Date?,
        transcriptRevision: Revision, range: MediaTimeRange, title: String?,
        tagIDs: Set<InterestID>, passages: [Evidence],
        passageHits: [EvidenceID: Set<InterestID>] = [:], statements: [MediaTimeRange] = [],
        sourceFullyAnalyzed: Bool = true
    ) {
        self.episodeID = episodeID; self.mediaVersionID = mediaVersionID; self.sourceID = sourceID
        self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.originalPublishedAt = originalPublishedAt; self.transcriptRevision = transcriptRevision
        self.range = range; self.title = title; self.tagIDs = tagIDs
        self.passages = passages
            .filter { $0.range.map { !$0.isEmpty } ?? false }
            .sorted { ($0.range?.start ?? .zero, $0.id.rawValue) < ($1.range?.start ?? .zero, $1.id.rawValue) }
        self.passageHits = passageHits; self.statements = statements
        self.sourceFullyAnalyzed = sourceFullyAnalyzed
    }

    /// Passt das Kapitel zu diesen Tags?
    public func matches(_ tags: Set<InterestID>, mode: TagMatchMode) -> Bool {
        guard !tags.isEmpty else { return false }
        switch mode {
        case .any: return !tagIDs.isDisjoint(with: tags)
        case .all: return tags.isSubset(of: tagIDs)
        }
    }

    /// Welche Belege welches Tag wörtlich nennen: Bezeichnung oder Alias,
    /// ohne Groß- und Kleinschreibung und Akzente. Ein Wort aus mindestens
    /// vier Zeichen trifft auch seine Beugungen und Zusammensetzungen am
    /// Wortanfang („Datenschutz“ in „Datenschutzes“), ein kürzeres nur
    /// sich selbst („EU“ nicht in „neu“).
    public static func textHits(
        in passages: [Evidence], terms: [InterestID: [String]]
    ) -> [EvidenceID: Set<InterestID>] {
        let prepared = terms.mapValues { $0.map(words).filter { !$0.isEmpty } }
        var result: [EvidenceID: Set<InterestID>] = [:]
        for passage in passages {
            let haystack = words(passage.quotedText)
            guard !haystack.isEmpty else { continue }
            for (tag, variants) in prepared where variants.contains(where: { occurs($0, in: haystack) }) {
                result[passage.id, default: []].insert(tag)
            }
        }
        return result
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    static func occurs(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for offset in 0...(haystack.count - needle.count) {
            let fits = needle.indices.allSatisfy { index in
                let word = haystack[offset + index], term = needle[index]
                return term.count >= 4 ? word.hasPrefix(term) : word == term
            }
            if fits { return true }
        }
        return false
    }
}

/// Grenzen eines Laufs.
public struct EditionLimits: Sendable {
    /// Höchstens so viele Teile entstehen auf einmal. Was danach übrig ist,
    /// bleibt für die nächste Ausgabe liegen und steht im Protokoll.
    public var maximumParts: Int
    /// Höchstens so viele Kapitel je Tag, gezählt nach dem Abzug von
    /// Gehörtem und Veröffentlichtem.
    public var maximumChaptersPerTag: Int

    public init(maximumParts: Int = 5, maximumChaptersPerTag: Int = 25) {
        self.maximumParts = max(1, maximumParts)
        self.maximumChaptersPerTag = max(1, maximumChaptersPerTag)
    }
}

/// Was ein Lauf veröffentlicht und was er liegen lässt.
public struct EditionRun: Sendable {
    /// Teil 1 zuerst.
    public let parts: [PersonalEpisode]
    /// Kapitel, die nach dem letzten erlaubten Teil keinen Platz hatten.
    public let droppedChapterCount: Int
    public let droppedDuration: MediaDuration
    /// Kapitel, die über der Grenze je Tag lagen.
    public let cappedChapterCount: Int
}

public enum EditionRunOutcome: Sendable {
    case published(EditionRun)
    /// Kein passendes ungehörtes Kapitel.
    case noNewMaterial(candidateCount: Int)
    /// Material da, aber unter der Mindestmenge der Automatik.
    case belowThreshold(available: MediaDuration, required: MediaDuration)
    /// Alles Passende steckt schon in einer Ausgabe dieses Updates.
    case alreadyPublished(PersonalEpisodeID)
}

extension PersonalEpisodePublisher {

    static let logger = Logger(subsystem: "com.godmodeai.podcastai", category: "editions")

    /// Baut die Teile einer Ausgabe aus Kapiteln.
    ///
    /// - `followedTagIDs`: gilt, wenn das Update selbst keine Tags nennt.
    /// - `previousEditions`: die bisherigen Ausgaben dieses Updates. Kein
    ///   Kapitel kommt zweimal vor, weder über Teile noch über Ausgaben.
    /// - `tagLabels`: für den Satz „Passt zu …“ in den Shownotes.
    ///
    /// Rein funktional, ohne Store und ohne Netz.
    public func makeEditions(
        feed: SmartPodcastFeed,
        chapters: [EditionChapter],
        ledger: ListeningLedger,
        previousEditions: [PersonalEpisode] = [],
        followedTagIDs: Set<InterestID> = [],
        tagLabels: [InterestID: String] = [:],
        requestedByUser: Bool = false,
        options: PublisherOptions = PublisherOptions(),
        limits: EditionLimits = EditionLimits(),
        now: Date = Date()
    ) -> EditionRunOutcome {

        let tags = feed.topicIDs.isEmpty ? followedTagIDs : Set(feed.topicIDs)
        let scope = Set(feed.restrictedToSourceIDs)
        let matching = chapters.filter {
            (scope.isEmpty || scope.contains($0.sourceID)) && $0.matches(tags, mode: feed.effectiveMatchMode)
        }
        guard !matching.isEmpty else { return .noNewMaterial(candidateCount: 0) }

        // 1. Veröffentlichtes vor allem anderen abziehen. Sonst hinge der
        //    Schlüssel des Laufs am Bestand der letzten Ausgabe, und Teil 2
        //    käme nie zustande.
        let published = PublishedChapters(previousEditions)
        var items: [ChapterItem] = []
        var excludedAsPublished = 0
        for chapter in Self.unique(matching) {
            if published.contains(chapter) { excludedAsPublished += 1; continue }
            let media = chapter.mediaVersionID
            if feed.unheardFilter == .neverStartedEpisodes, !ledger.heard(in: media).isEmpty { continue }
            let open = ledger.heard(in: media).remainder(of: chapter.range)
                .subtracting(published.covered[media] ?? IntervalSet())
                .droppingFragments(shorterThan: options.minimumSegmentDuration)
            guard !open.isEmpty else { continue }
            let matched = feed.topicIDs.isEmpty
                ? chapter.tagIDs.intersection(tags).sorted { $0.rawValue < $1.rawValue }
                : feed.topicIDs.filter { chapter.tagIDs.contains($0) }
            items.append(ChapterItem(chapter: chapter, open: open, tags: matched))
        }
        guard !items.isEmpty else {
            if excludedAsPublished > 0, let latest = previousEditions.max(by: { $0.publishedAt < $1.publishedAt }) {
                return .alreadyPublished(latest.id)
            }
            return .noNewMaterial(candidateCount: matching.count)
        }

        // 2. Neueste Quelle zuerst, dann die Grenze je Tag. Die Grenze
        //    greift erst hier, nach dem Hörzustand: vorher hätten gehörte
        //    Kapitel ungehörten den Platz genommen.
        items.sort(by: ChapterItem.newestFirst)
        // Zwei Kapitel, die sich überschneiden (etwa aus zwei Einordnungen
        // derselben Folge auf zwei Geräten): die Überschneidung bekommt
        // nur das erste. Kein Stück Ton kommt in einem Lauf zweimal vor.
        var claimed: [MediaVersionID: IntervalSet] = [:]
        items = items.compactMap { item in
            let media = item.chapter.mediaVersionID
            let open = item.open.subtracting(claimed[media] ?? IntervalSet())
                .droppingFragments(shorterThan: options.minimumSegmentDuration)
            claimed[media, default: IntervalSet()].insert(item.chapter.range)
            guard !open.isEmpty else { return nil }
            return ChapterItem(chapter: item.chapter, open: open, tags: item.tags)
        }
        guard !items.isEmpty else { return .noNewMaterial(candidateCount: matching.count) }
        var perTag: [InterestID: Int] = [:]
        var capped = 0
        items = items.filter { item in
            guard item.tags.contains(where: { perTag[$0, default: 0] < limits.maximumChaptersPerTag }) else {
                capped += 1
                return false
            }
            for tag in item.tags { perTag[tag, default: 0] += 1 }
            return true
        }

        // 3. Schlüssel des Laufs aus dem, was wirklich neu ist.
        let batchKey = StableDigest.hex(ofUnordered: items.flatMap { item in
            item.open.ranges.map {
                "\(item.chapter.mediaVersionID.rawValue):\($0.start.milliseconds)-\($0.end.milliseconds)"
            }
        })
        if let earlier = previousEditions.first(where: { $0.batchKey == batchKey }) {
            return .alreadyPublished(earlier.id)
        }

        // 4. Schwelle der Automatik.
        let available = MediaDuration(milliseconds: items.reduce(0) { $0 + $1.open.totalDuration.milliseconds })
        let required = feed.publicationPolicy.minimumMaterial
        if !requestedByUser, feed.publicationPolicy.isAutomatic, available < required {
            return .belowThreshold(available: available, required: required)
        }

        // 5. Schneiden und auf Teile verteilen, streng der Reihe nach.
        let budget = feed.partBudget?.milliseconds
        let planned = items.map { cut($0, budget: budget, tags: tags, options: options) }
        var parts: [[PlannedChapter]] = [[]]
        var used: Int64 = 0
        var dropped: [PlannedChapter] = []
        for chapter in planned {
            let transition = parts[parts.count - 1].isEmpty ? 0 : options.transition.milliseconds
            if used + transition + chapter.listening <= budget ?? .max {
                parts[parts.count - 1].append(chapter)
                used += transition + chapter.listening
            } else if parts.count < limits.maximumParts {
                parts.append([chapter])
                used = chapter.listening
            } else {
                dropped.append(chapter)
            }
        }
        let droppedDuration = MediaDuration(milliseconds: dropped.reduce(0) { $0 + $1.coreLength })
        if !dropped.isEmpty {
            Self.logger.notice("""
                Themen-Update \(feed.id.rawValue, privacy: .public): \(dropped.count) Kapitel \
                (\(droppedDuration.seconds, format: .fixed(precision: 0)) s) nach \(limits.maximumParts) Teilen \
                liegen gelassen: \(dropped.map(\.item.key).joined(separator: ", "), privacy: .public)
                """)
        }
        if capped > 0 {
            Self.logger.notice("""
                Themen-Update \(feed.id.rawValue, privacy: .public): \(capped) Kapitel über der Grenze \
                von \(limits.maximumChaptersPerTag) je Tag
                """)
        }

        // 6. Je Teil ein Manifest.
        let editions = parts.enumerated().map { index, chapters in
            buildPart(
                index + 1, of: chapters, feed: feed, batchKey: batchKey,
                candidateCount: items.count, remaining: droppedDuration,
                tagLabels: tagLabels, options: options, now: now)
        }
        return .published(EditionRun(
            parts: editions, droppedChapterCount: dropped.count, droppedDuration: droppedDuration,
            cappedChapterCount: capped))
    }

    /// Schlüssel eines weiteren Teils. Teil 1 trägt den Schlüssel des Laufs.
    static func partKey(_ batchKey: String, part: Int) -> String {
        part <= 1 ? batchKey : StableDigest.hex(ofOrdered: [batchKey, "part", String(part)])
    }

    /// Dasselbe Kapitel zweimal in der Liste, etwa aus zwei Pfaden: das
    /// erste gilt.
    static func unique(_ chapters: [EditionChapter]) -> [EditionChapter] {
        var seen: Set<String> = []
        return chapters.filter { seen.insert(ChapterItem.key(of: $0)).inserted }
    }

    // MARK: - Schneiden

    /// Ein Kapitel, bereit für einen Teil.
    struct PlannedChapter {
        let item: ChapterItem
        /// Kern und Abspielbereich jeder Stelle, in der Zeitfolge der Folge.
        let pieces: [(core: MediaTimeRange, playback: MediaTimeRange)]
        let isWhole: Bool
        /// Hörlänge samt Übergängen zwischen den Stellen, in Millisekunden.
        let listening: Int64
        var coreLength: Int64 { pieces.reduce(0) { $0 + $1.core.duration.milliseconds } }
    }

    /// Ein Kapitel geht ganz hinein, wenn es in einen Teil passt. Sonst
    /// nimmt der Code die Belege mit Tag-Treffer, jeweils mit Vorlauf, bis
    /// der Teil voll ist. Trifft kein Beleg ein Tag wörtlich, beginnt er
    /// vorn im Kapitel.
    func cut(
        _ item: ChapterItem, budget: Int64?, tags: Set<InterestID>, options: PublisherOptions
    ) -> PlannedChapter {
        let chapterStart = item.chapter.range.start.milliseconds
        let lead = options.contextLeadIn.milliseconds

        func playback(for core: MediaTimeRange) -> MediaTimeRange {
            MediaTimeRange(
                start: MediaTime(milliseconds: max(chapterStart, core.start.milliseconds - lead)),
                end: core.end)
        }
        func length(_ pieces: [(core: MediaTimeRange, playback: MediaTimeRange)]) -> Int64 {
            let audio = pieces.reduce(Int64(0)) {
                $0 + $1.playback.duration.listeningDuration(atRate: options.playbackRate).milliseconds
            }
            return audio + Int64(max(0, pieces.count - 1)) * options.transition.milliseconds
        }

        let whole = item.open.ranges.map { (core: $0, playback: playback(for: $0)) }
        let wholeLength = length(whole)
        guard let budget, wholeLength > budget else {
            return PlannedChapter(item: item, pieces: whole, isWhole: true, listening: wholeLength)
        }

        // Die Stellen mit Treffer, nur ihr ungehörter Teil.
        let hits = item.chapter.passages.filter {
            !(item.chapter.passageHits[$0.id] ?? []).isDisjoint(with: tags)
        }
        var pieces: [(core: MediaTimeRange, playback: MediaTimeRange)] = []
        var total: Int64 = 0
        var firstCore: MediaTimeRange?
        for passage in hits.isEmpty ? item.chapter.passages : hits {
            guard let range = passage.range else { continue }
            guard let core = item.open.intersection(IntervalSet(range)).ranges
                .max(by: { $0.duration < $1.duration }) else { continue }
            if firstCore == nil { firstCore = core }
            var next = (core: core, playback: playback(for: core))
            // Berührt der Vorlauf die vorige Stelle, wird es eine Stelle.
            if let last = pieces.last, next.playback.start <= last.core.end {
                next = (core: MediaTimeRange(start: last.core.start, end: max(last.core.end, core.end)),
                        playback: MediaTimeRange(start: last.playback.start, end: max(last.playback.end, core.end)))
                let candidate = Array(pieces.dropLast()) + [next]
                guard length(candidate) <= budget else { break }
                pieces = candidate
            } else {
                let candidate = pieces + [next]
                guard length(candidate) <= budget else { break }
                pieces = candidate
            }
            total = length(pieces)
        }
        // Schon die erste Stelle ist länger als ein Teil: dann gekürzt,
        // und zwar diese Stelle, nicht der Anfang des Kapitels.
        if pieces.isEmpty, let first = firstCore ?? item.open.ranges.first {
            let playbackStart = playback(for: first).start
            let room = MediaDuration(milliseconds: Int64(Double(budget) * options.playbackRate))
            let played = MediaTimeRange(start: playbackStart, end: first.end).clamped(toDuration: room)
            let core = MediaTimeRange(start: max(first.start, played.start), end: played.end)
            pieces = [(core: core, playback: played)]
            total = length(pieces)
        }
        return PlannedChapter(item: item, pieces: pieces, isWhole: false, listening: total)
    }

    // MARK: - Ein Teil

    func buildPart(
        _ part: Int, of chapters: [PlannedChapter], feed: SmartPodcastFeed, batchKey: String,
        candidateCount: Int, remaining: MediaDuration, tagLabels: [InterestID: String],
        options: PublisherOptions, now: Date
    ) -> PersonalEpisode {
        var segments: [PersonalEpisodeSegment] = []
        var overview: [EditionOverviewEntry] = []
        var cursor: Int64 = 0

        for planned in chapters {
            let chapter = planned.item.chapter
            let reason = Self.reason(tags: planned.item.tags, labels: tagLabels, chapter: chapter)
            var ids: [SegmentID] = []
            for piece in planned.pieces {
                let length = piece.playback.duration.milliseconds
                let virtual = MediaTimeRange(start: MediaTime(milliseconds: cursor),
                                             end: MediaTime(milliseconds: cursor + length))
                cursor += length + options.transition.milliseconds
                let id = SegmentID(stable: "\(chapter.mediaVersionID.rawValue)|"
                                   + "\(piece.core.start.milliseconds)|\(piece.core.end.milliseconds)")
                ids.append(id)
                let evidence = chapter.passages.filter {
                    guard let range = $0.range else { return false }
                    return piece.core.overlaps(range)
                }.map(\.id)
                segments.append(PersonalEpisodeSegment(
                    id: id, episodeID: chapter.episodeID, mediaVersionID: chapter.mediaVersionID,
                    transcriptRevision: chapter.transcriptRevision, evidenceIDs: evidence,
                    coreRange: piece.core, playbackRange: piece.playback, virtualRange: virtual,
                    reason: reason, topicIDs: planned.item.tags,
                    contextReplay: piece.playback.start < piece.core.start,
                    sourceID: chapter.sourceID, sourceTitle: chapter.sourceTitle,
                    episodeTitle: chapter.episodeTitle, originalPublishedAt: chapter.originalPublishedAt,
                    chapterRange: chapter.range, chapterTitle: chapter.title))
            }
            let statements = chapter.statements.filter { statement in
                planned.pieces.contains { $0.core.contains(statement.start) }
            }.count
            overview.append(EditionOverviewEntry(
                segmentIDs: ids, episodeID: chapter.episodeID, sourceID: chapter.sourceID,
                sourceTitle: chapter.sourceTitle, episodeTitle: chapter.episodeTitle,
                chapterTitle: chapter.title, originalPublishedAt: chapter.originalPublishedAt,
                virtualStart: segments.first { $0.id == ids.first }?.virtualRange.start ?? .zero,
                newStatementCount: statements, tagIDs: planned.item.tags, isWholeChapter: planned.isWhole))
        }

        let coverage = EditionCoverage(
            candidateCount: candidateCount, includedCount: chapters.count, remaining: remaining,
            partiallyAnalyzedSourceIDs: Array(Set(
                chapters.filter { !$0.item.chapter.sourceFullyAnalyzed }.map(\.item.chapter.sourceID)
            )).sorted { $0.rawValue < $1.rawValue })
        let key = Self.partKey(batchKey, part: part)
        let titles = EditionTitleBuilder()
        let base = titles.title(for: feed, segments: segments, at: now)
        return PersonalEpisode(
            id: PersonalEpisodeID(stable: key), feedID: feed.id, policyRevision: feed.policyRevision,
            batchKey: key, title: titles.title(base, part: part),
            subtitle: titles.subtitle(for: segments, coverage: coverage),
            // Teil 1 ist der neueste, damit er in Listen nach Datum oben steht.
            publishedAt: now.addingTimeInterval(-Double(part - 1)),
            segments: segments, shownotes: ShownotesBuilder().build(from: segments),
            coverAssetID: feed.confirmedCoverAssetID, coverage: coverage,
            part: part, runKey: batchKey, overviewEntries: overview)
    }

    static func reason(tags: [InterestID], labels: [InterestID: String], chapter: EditionChapter) -> String {
        let named = tags.compactMap { labels[$0] }
        guard !named.isEmpty else { return chapter.title ?? chapter.episodeTitle }
        return String(localized: "Passt zu \(named.formatted(.list(type: .and)))", bundle: .module)
    }
}

// MARK: - Bausteine

/// Ein passendes Kapitel mit seinem ungehörten, noch nicht veröffentlichten Teil.
struct ChapterItem {
    let chapter: EditionChapter
    let open: IntervalSet
    /// Die Tags des Updates, die das Kapitel trägt, in der Reihenfolge des Updates.
    let tags: [InterestID]

    var key: String { Self.key(of: chapter) }

    static func key(of chapter: EditionChapter) -> String {
        "\(chapter.mediaVersionID.rawValue)|\(chapter.range.start.milliseconds)"
    }

    /// Neueste Quelle zuerst, eine Folge am Stück, ihre Kapitel in der
    /// Zeitfolge des Originals.
    static func newestFirst(_ lhs: ChapterItem, _ rhs: ChapterItem) -> Bool {
        let l = lhs.chapter.originalPublishedAt ?? .distantPast
        let r = rhs.chapter.originalPublishedAt ?? .distantPast
        if l != r { return l > r }
        if lhs.chapter.episodeID != rhs.chapter.episodeID {
            return lhs.chapter.episodeID.rawValue < rhs.chapter.episodeID.rawValue
        }
        if lhs.chapter.range.start != rhs.chapter.range.start {
            return lhs.chapter.range.start < rhs.chapter.range.start
        }
        return lhs.chapter.mediaVersionID.rawValue < rhs.chapter.mediaVersionID.rawValue
    }
}

/// Was frühere Ausgaben eines Updates schon enthalten.
///
/// Abschnitte seit 0.11 tragen ihr Kapitel. Ein Kapitel gilt als
/// veröffentlicht, wenn es sich mit einem davon zu mehr als der Hälfte des
/// kürzeren deckt; so trifft es auch, wenn sich abgeleitete Grenzen leicht
/// verschoben haben. Was ein Kapitel mit weniger Überschneidung noch mit
/// einem veröffentlichten teilt, wird wie Gehörtes abgezogen, ebenso die
/// Stellen älterer Abschnitte, die nur ihre Stelle kennen.
struct PublishedChapters {
    var chapters: [MediaVersionID: [MediaTimeRange]] = [:]
    /// Alles, was schon in einer Ausgabe steckt: ganze Kapitel und die
    /// Stellen älterer Abschnitte.
    var covered: [MediaVersionID: IntervalSet] = [:]

    init(_ editions: [PersonalEpisode]) {
        for segment in editions.flatMap(\.segments) {
            if let range = segment.chapterRange {
                chapters[segment.mediaVersionID, default: []].append(range)
                covered[segment.mediaVersionID, default: IntervalSet()].insert(range)
            } else {
                covered[segment.mediaVersionID, default: IntervalSet()].insert(segment.coreRange)
            }
        }
    }

    func contains(_ chapter: EditionChapter) -> Bool {
        (chapters[chapter.mediaVersionID] ?? []).contains { earlier in
            guard let overlap = earlier.intersection(chapter.range) else { return false }
            let shorter = min(earlier.duration.milliseconds, chapter.range.duration.milliseconds)
            return shorter > 0 && overlap.duration.milliseconds * 2 > shorter
        }
    }
}

extension PersonalEpisode {
    /// Die Teile des jüngsten Laufs, Teil 1 zuerst. Leer ohne Ausgabe.
    public static func latestRun(in editions: [PersonalEpisode]) -> [PersonalEpisode] {
        guard let latest = editions.max(by: { $0.publishedAt < $1.publishedAt }) else { return [] }
        return editions.filter { $0.runKey == latest.runKey }.sorted { $0.part < $1.part }
    }

    /// Wie viel von allen Teilen zusammen gehört ist, nach Länge gewichtet.
    /// Wer nur Teil 1 von fünf gehört hat, hat den Lauf nicht gehört.
    public static func heardFraction(of parts: [PersonalEpisode], in ledger: ListeningLedger) -> Double {
        var total: Double = 0
        var heard: Double = 0
        for part in parts {
            let length = Double(part.segments.reduce(Int64(0)) { $0 + $1.coreRange.duration.milliseconds })
            guard length > 0 else { continue }
            total += length
            heard += length * part.heardFraction(in: ledger)
        }
        return total > 0 ? heard / total : 0
    }
}

extension EditionTitleBuilder {
    /// „Mein KI Update · 24.09.“, ab Teil 2 „Mein KI Update · 24.09., Teil 2“.
    public func title(_ base: String, part: Int) -> String {
        part <= 1 ? base : String(localized: "\(base), Teil \(part)", bundle: .module)
    }
}
