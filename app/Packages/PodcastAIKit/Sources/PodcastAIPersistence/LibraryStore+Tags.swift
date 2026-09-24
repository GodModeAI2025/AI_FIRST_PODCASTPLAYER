//
//  LibraryStore+Tags.swift
//  PodcastAIPersistence
//
//  Tags und Kapitel-Tags, seit 0.10.
//
//  Ein Tag ist eine Zeile `StoredInterest`. Die Kapitel-Tags zeigen über
//  `interestIdentifier` auf sie und tragen den Schlüssel des Tags selbst,
//  damit Trends ohne das Tag zählen können.
//
//  Zusammenlegen: Zwei Tags mit demselben Schlüssel sind eines. Das
//  passiert beim ersten Laden nach 0.10 („USA“ und „Vereinigte Staaten“
//  als zwei alte Interessen) und wenn zwei Geräte dasselbe Tag
//  gleichzeitig anlegen. Es bleibt die Zeile mit dem ältesten `createdAt`,
//  bei Gleichstand die kleinere Kennung. Beides wird abgeglichen, also
//  wählt jedes Gerät dieselbe. Alle Verweise auf die anderen Kennungen
//  (Kapitel-Tags, Themenfeeds, Ausgaben, gemerkte Stellen) zeigen danach
//  auf sie.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore
import PodcastAIKnowledge
import PodcastAISmartFeeds

extension LibraryStore {

    // MARK: - Tags

    /// Alle Tags, auch neutrale und erkannte. Vorschläge nicht.
    public func tags() throws -> [Tag] {
        try modelContext.fetch(FetchDescriptor<StoredInterest>(sortBy: [SortDescriptor(\.createdAt)]))
            .uniqued(by: \.identifier)
            .map(\.snapshot)
            .filter { $0.origin != .suggestedBySystem }
            .map(\.tag)
    }

    /// Plus oder Minus. Minus löscht nichts: Das Tag bleibt sichtbar und
    /// neutral, seine Kapitel-Tags bleiben ebenso.
    public func setStance(_ stance: TagStance, forTag id: InterestID) throws {
        let identifier = id.rawValue
        let rows = try modelContext.fetch(
            FetchDescriptor<StoredInterest>(predicate: #Predicate { $0.identifier == identifier }))
        guard !rows.isEmpty else { return }
        for row in rows { row.stanceRaw = stance.rawValue }
        try modelContext.save()
    }

    /// Das Tag zu einer Schreibweise, über Schlüssel oder Alias.
    public func resolveTag(_ label: String) throws -> Tag? {
        TagNormalizer.resolve(label, in: try tags())
    }

    /// Ein Tag, das die App im Inhalt erkannt hat.
    ///
    /// Gibt es schon ein Tag mit diesem Schlüssel oder Alias, kommt es
    /// zurück, und nichts wird angelegt. Sonst entsteht ein neutrales Tag
    /// mit `origin = detected` und einer Kennung aus dem Schlüssel.
    /// `SensitiveTopicPolicy` entscheidet vorher, ob ein neues Tag überhaupt
    /// entstehen darf; ohne Erlaubnis kommt `nil`.
    public func addDetectedTag(label: String, seenAt: Date = Date()) throws -> Tag? {
        if let existing = try resolveTag(label) {
            try noteFirstSeen([existing.id.rawValue: seenAt])
            return try tags().first { $0.id == existing.id } ?? existing
        }
        guard let tag = TagNormalizer.makeDetectedTag(label: label, seenAt: seenAt) else { return nil }
        let row = StoredInterest(identifier: tag.id.rawValue, label: tag.label)
        row.kindRaw = InterestKind.topic.rawValue
        row.originRaw = tag.origin.rawValue
        row.stanceRaw = tag.stance.rawValue
        row.normalizedKey = tag.normalizedKey
        row.firstSeenAt = tag.firstSeenAt
        modelContext.insert(row)
        try modelContext.save()
        return tag
    }

    /// Setzt `firstSeenAt`, wo es fehlt oder später liegt.
    private func noteFirstSeen(_ dates: [String: Date]) throws {
        guard !dates.isEmpty else { return }
        let keys = Set(dates.keys)
        var changed = false
        for row in try modelContext.fetch(FetchDescriptor<StoredInterest>(
            predicate: #Predicate { keys.contains($0.identifier) })) {
            guard let date = dates[row.identifier] else { continue }
            let earlier = Self.earlier(row.firstSeenAt, date)
            if earlier != row.firstSeenAt { row.firstSeenAt = earlier; changed = true }
        }
        if changed { try modelContext.save() }
    }

    static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): min(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    // MARK: - Zusammenlegen beim Laden

    /// Trägt fehlende Schlüssel ein und legt Tags mit gleichem Schlüssel
    /// zusammen. Läuft in ``removeDuplicatesWithReport()``, also bei jedem
    /// Laden und nach jedem Abgleich.
    func settleTags() throws {
        let rows = try modelContext.fetch(FetchDescriptor<StoredInterest>())
        var filled = false
        for row in rows where row.normalizedKey.isEmpty && !row.label.isEmpty {
            let key = TagNormalizer.key(for: row.label)
            guard !key.isEmpty else { continue }
            row.normalizedKey = key
            filled = true
        }
        if filled { try modelContext.save() }

        var groups: [String: [StoredInterest]] = [:]
        for row in rows where !row.normalizedKey.isEmpty && !row.identifier.isEmpty {
            groups[row.normalizedKey, default: []].append(row)
        }

        var survivorOf: [InterestID: InterestID] = [:]
        var dropped: [StoredInterest] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }
            var firstCreated: [String: Date] = [:]
            for row in group {
                firstCreated[row.identifier] = min(firstCreated[row.identifier] ?? row.createdAt, row.createdAt)
            }
            guard firstCreated.count > 1,
                  let survivor = firstCreated.min(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key
            else { continue }
            // Feste Reihenfolge, damit jedes Gerät dasselbe Ergebnis schreibt.
            let others = group.filter { $0.identifier != survivor }
                .sorted { ($0.createdAt, $0.identifier) < ($1.createdAt, $1.identifier) }
            for keep in group where keep.identifier == survivor {
                Self.merge(others, into: keep)
            }
            for other in others {
                survivorOf[InterestID(rawValue: other.identifier)] = InterestID(rawValue: survivor)
                dropped.append(other)
            }
        }
        guard !survivorOf.isEmpty else { return }
        try rewriteInterestReferences(survivorOf)
        // Erst die umgeschriebenen Verweise sichern, dann die Kopien löschen.
        try modelContext.save()
        for row in dropped { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Führt die Angaben zusammen. Wer einem der Tags gefolgt ist, folgt dem
    /// zusammengelegten. Die Bezeichnungen der anderen werden Aliasse.
    static func merge(_ others: [StoredInterest], into keep: StoredInterest) {
        var aliases = keep.keywords
        var seen = Set(([keep.label] + aliases).map { $0.lowercased() })
        for other in others {
            for alias in [other.label] + other.keywords where seen.insert(alias.lowercased()).inserted {
                aliases.append(alias)
            }
        }
        keep.keywords = aliases

        let all = [keep] + others
        if all.contains(where: { $0.stanceRaw == TagStance.follow.rawValue }) {
            keep.stanceRaw = TagStance.follow.rawValue
        }
        let origins = Set(all.map(\.originRaw))
        for origin in [InterestOrigin.confirmedByUser, .detected, .suggestedBySystem]
        where origins.contains(origin.rawValue) {
            keep.originRaw = origin.rawValue
            break
        }
        // Läuft eines nie ab, läuft das zusammengelegte nie ab.
        keep.expiresAt = all.contains { $0.expiresAt == nil } ? nil : all.compactMap(\.expiresAt).max()
        keep.firstSeenAt = all.map(\.firstSeenAt).reduce(nil, earlier)
    }

    /// Schreibt Verweise von zusammengelegten Tags auf die Kennung um, die
    /// bleibt: Kapitel-Tags, Themenfeeds, Ausgaben und gemerkte Stellen.
    /// Ein JSON wird nur neu geschrieben, wenn sich etwas ändert, sonst
    /// ginge jedes Laden als Änderung durch iCloud.
    func rewriteInterestReferences(_ map: [InterestID: InterestID]) throws {
        let old = Set(map.keys.map(\.rawValue))
        for tag in try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { old.contains($0.interestIdentifier) })) {
            if let survivor = map[InterestID(rawValue: tag.interestIdentifier)] {
                tag.interestIdentifier = survivor.rawValue
            }
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredSmartFeed>()) {
            guard let feed = try? Self.decoder.decode(SmartPodcastFeed.self, from: row.payload),
                  feed.topicIDs.contains(where: { map[$0] != nil }) else { continue }
            let payload = try Self.encoder.encode(feed.replacingTopicIDs(map))
            if payload != row.payload { row.payload = payload }
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredPersonalEpisode>()) {
            guard let edition = try? Self.decoder.decode(PersonalEpisode.self, from: row.payload),
                  edition.segments.contains(where: { $0.topicIDs.contains { map[$0] != nil } })
            else { continue }
            let payload = try Self.encoder.encode(edition.replacingTopicIDs(map))
            if payload != row.payload { row.payload = payload }
        }

        for row in try modelContext.fetch(FetchDescriptor<StoredHighlight>()) {
            guard let data = row.payload,
                  var highlight = try? Self.decoder.decode(Highlight.self, from: data),
                  highlight.interestIDs.contains(where: { map[$0] != nil }) else { continue }
            highlight.interestIDs = highlight.interestIDs.replacingInterestIDs(map)
            let payload = try Self.encoder.encode(highlight)
            if payload != data { row.payload = payload }
        }
    }

    /// Kapitel-Tags zu Folgen, die gelöscht sind. Sie kommen an, wenn ein
    /// anderes Gerät noch klassifiziert hat, während hier gelöscht wurde.
    /// Gelöscht heißt: jede Kopie trägt das Merkzeichen. Ein Merkzeichen
    /// ohne Quelle neben einer lebenden Kopie unter einem neuen Abo zählt
    /// nicht, siehe `reattachOrphanedEpisodes`.
    func removeChapterTagsOfRemovedEpisodes() throws {
        var removedDescriptor = FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.removedAt != nil })
        removedDescriptor.propertiesToFetch = [\.identifier]
        var removed = Set(try modelContext.fetch(removedDescriptor).map(\.identifier))
        guard !removed.isEmpty else { return }
        var liveDescriptor = FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.removedAt == nil })
        liveDescriptor.propertiesToFetch = [\.identifier]
        removed.subtract(try modelContext.fetch(liveDescriptor).map(\.identifier))
        guard !removed.isEmpty else { return }
        for tag in try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { removed.contains($0.episodeIdentifier) })) {
            modelContext.delete(tag)
        }
    }

    /// Schreibt Schlüssel und Kennung der Kapitel-Tags eines Tags um, wenn
    /// seine neue Bezeichnung einen neuen Schlüssel ergibt.
    func moveChapterTags(ofInterest identifier: String, toKey key: String) throws {
        for row in try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.interestIdentifier == identifier })) {
            row.normalizedKey = key
            row.identifier = ChapterTag.identifier(
                mediaVersionID: MediaVersionID(rawValue: row.mediaVersionIdentifier),
                chapterStartMs: row.chapterStartMs, normalizedKey: key).rawValue
        }
    }

    // MARK: - Kapitel-Tags

    /// Ersetzt die Kapitel-Tags einer Folge durch die einer Einordnung.
    ///
    /// Alle Zeilen der Folge aus dieser oder einer älteren Fassung des
    /// Transkripts gehen, die neuen kommen. Liegen schon Tags aus einer
    /// neueren Fassung vor, oder ist die Folge gelöscht, schreibt die
    /// Einordnung nichts und das Ergebnis ist `false`.
    @discardableResult
    public func save(
        chapterTags: [ChapterTag], forEpisode episodeID: EpisodeID, transcriptRevision: Revision
    ) throws -> Bool {
        let key = episodeID.rawValue
        let episodes = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.identifier == key }))
        if !episodes.isEmpty, episodes.allSatisfy({ $0.removedAt != nil }) { return false }

        let existing = try modelContext.fetch(
            FetchDescriptor<StoredChapterTag>(predicate: #Predicate { $0.episodeIdentifier == key }))
        if existing.contains(where: { $0.transcriptRevisionValue > transcriptRevision.value }) { return false }
        for row in existing { modelContext.delete(row) }

        var written: Set<ChapterTagID> = []
        var firstSeen: [String: Date] = [:]
        for tag in chapterTags where tag.episodeID == episodeID && written.insert(tag.id).inserted {
            let row = StoredChapterTag(identifier: tag.id.rawValue)
            row.apply(tag)
            row.transcriptRevisionValue = transcriptRevision.value
            modelContext.insert(row)
            let interest = tag.interestID.rawValue
            firstSeen[interest] = min(firstSeen[interest] ?? tag.createdAt, tag.createdAt)
        }
        try modelContext.save()
        try noteFirstSeen(firstSeen)
        return true
    }

    /// Die Kapitel-Tags einer Folge, nach Kapitelstart.
    public func chapterTags(forEpisode episodeID: EpisodeID) throws -> [ChapterTag] {
        let key = episodeID.rawValue
        return try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.episodeIdentifier == key },
            sortBy: [SortDescriptor(\.chapterStartMs), SortDescriptor(\.normalizedKey)]))
            .uniqued(by: \.identifier).map(\.snapshot)
    }

    /// Alle Kapitel mit einem Tag, neueste Folge zuerst.
    public func chapterTags(forKey normalizedKey: String) throws -> [ChapterTag] {
        try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.normalizedKey == normalizedKey },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse), SortDescriptor(\.identifier)]))
            .uniqued(by: \.identifier).map(\.snapshot)
    }

    /// Kapitel-Tags von Folgen, die im Zeitraum `[start, end)` erschienen
    /// sind. Ohne Erscheinungsdatum zählt, wann das Tag entstand.
    public func chapterTags(publishedFrom start: Date, to end: Date) throws -> [ChapterTag] {
        try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate {
                ($0.publishedAt ?? $0.createdAt) >= start && ($0.publishedAt ?? $0.createdAt) < end
            },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse), SortDescriptor(\.identifier)]))
            .uniqued(by: \.identifier).map(\.snapshot)
    }

    /// Wie viele Kapitel je Tag und Quelle im Zeitraum `[start, end)`
    /// dazukamen. Reine Zählung, Grundlage für „Angesagt“.
    public func chapterTagCounts(publishedFrom start: Date, to end: Date) throws -> [ChapterTagCount] {
        struct Bucket: Hashable { let key: String; let source: String }
        var chapters: [Bucket: Set<String>] = [:]
        for tag in try chapterTags(publishedFrom: start, to: end) {
            let bucket = Bucket(key: tag.normalizedKey, source: tag.sourceID.rawValue)
            chapters[bucket, default: []].insert("\(tag.mediaVersionID.rawValue)|\(tag.chapterStartMs)")
        }
        return chapters
            .map { ChapterTagCount(normalizedKey: $0.key.key, sourceID: SourceID(rawValue: $0.key.source),
                                   chapterCount: $0.value.count) }
            .sorted {
                ($1.chapterCount, $0.normalizedKey, $0.sourceID.rawValue)
                    < ($0.chapterCount, $1.normalizedKey, $1.sourceID.rawValue)
            }
    }

    // MARK: - Nur für Tests

    /// Nur für Tests: eine Zeile eines Interesses ohne Prüfung, so wie sie
    /// ein anderes Gerät oder eine ältere Version angelegt hat.
    func insertInterestRowForTesting(
        identifier: String, label: String, createdAt: Date,
        normalizedKey: String = "", stance: TagStance = .follow,
        origin: InterestOrigin = .confirmedByUser, keywords: [String] = []
    ) throws {
        let row = StoredInterest(identifier: identifier, label: label)
        row.createdAt = createdAt
        row.normalizedKey = normalizedKey
        row.stanceRaw = stance.rawValue
        row.originRaw = origin.rawValue
        row.keywords = keywords
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Nur für Tests: eine Zeile eines Kapitel-Tags ohne Prüfung auf
    /// Doppelte, wie sie der Abgleich vom anderen Gerät bringt.
    func insertChapterTagCopyForTesting(_ tag: ChapterTag) throws {
        let row = StoredChapterTag(identifier: tag.id.rawValue)
        row.apply(tag)
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Nur für Tests: die gespeicherten Schlüssel der Interessen.
    func interestKeysForTesting() throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try modelContext.fetch(FetchDescriptor<StoredInterest>()) {
            result[row.identifier] = row.normalizedKey
        }
        return result
    }
}
#endif
