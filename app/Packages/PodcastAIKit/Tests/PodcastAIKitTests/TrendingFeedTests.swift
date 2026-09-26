//
//  TrendingFeedTests.swift
//  PodcastAIKitTests
//
//  Das Themen-Update „Angesagt“ aus 0.12: Seine Tags folgen den Trends,
//  ohne Trends entsteht keine Ausgabe, die Kennung ist auf jedem Gerät
//  dieselbe, und Tags mit Minus bleiben draußen. Dazu das Abgleichen
//  zwischen zwei Geräten und das Bereinigen, wenn beide das Update
//  gleichzeitig angelegt haben.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Angesagt als Themen-Update")
struct TrendingFeedTests {

    // MARK: Bausteine

    private let euAct = InterestID(rawValue: "tag-ki-verordnung")
    private let privacy = InterestID(rawValue: "tag-datenschutz")
    private let chips = InterestID(rawValue: "tag-chips")
    private let cars = InterestID(rawValue: "tag-auto")

    private func tag(_ id: InterestID, stance: TagStance, origin: InterestOrigin) -> PodcastAICore.Tag {
        PodcastAICore.Tag(id: id, label: id.rawValue, normalizedKey: id.rawValue, stance: stance, origin: origin)
    }

    /// Ein Tag, das die App erkannt hat und das niemand bewertet hat.
    private func detected(_ id: InterestID) -> PodcastAICore.Tag { tag(id, stance: .neutral, origin: .detected) }
    /// Ein Tag mit Plus.
    private func followed(_ id: InterestID) -> PodcastAICore.Tag { tag(id, stance: .follow, origin: .confirmedByUser) }
    /// Ein Tag, dem jemand mit Minus das Folgen entzogen hat.
    private func unfollowed(_ id: InterestID) -> PodcastAICore.Tag { tag(id, stance: .neutral, origin: .confirmedByUser) }

    private func trending(_ tag: PodcastAICore.Tag, chapters: Int = 6) -> TrendingTag {
        TrendingTag(tag: tag, trend: TagTrend(
            normalizedKey: tag.normalizedKey, recentChapters: chapters, sourceCount: 3,
            baselineChapters: 0, weeklyAverage: 0))
    }

    private func trendingFeed(_ tags: [InterestID]) -> SmartPodcastFeed {
        TrendingFeed.makeFeed(title: "Angesagt", tagIDs: tags, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    /// Ein Kapitel von fünf Minuten mit einem Beleg je Minute.
    private func chapter(media: String, tags: Set<InterestID>) -> EditionChapter {
        let passages = (0..<5).map { minute in
            Evidence(
                id: EvidenceID(rawValue: "\(media)-\(minute)"), mediaVersionID: MediaVersionID(rawValue: media),
                episodeID: EpisodeID(rawValue: "ep-\(media)"), sourceID: SourceID(rawValue: "s-\(media)"),
                transcriptID: TranscriptID(rawValue: "t"), transcriptRevision: .initial,
                range: range(Int64(minute) * 60_000, Int64(minute + 1) * 60_000), quotedText: "Gespräch")
        }
        return EditionChapter(
            episodeID: EpisodeID(rawValue: "ep-\(media)"), mediaVersionID: MediaVersionID(rawValue: media),
            sourceID: SourceID(rawValue: "s-\(media)"), sourceTitle: "Quelle \(media)",
            episodeTitle: "Folge \(media)", originalPublishedAt: Date(timeIntervalSince1970: 1_799_900_000),
            transcriptRevision: .initial, range: range(0, 300_000), title: "Kapitel",
            tagIDs: tags, passages: passages, statements: [range(0, 30_000)])
    }

    private func editions(
        _ feed: SmartPodcastFeed, _ chapters: [EditionChapter], followed: Set<InterestID> = []
    ) -> EditionRunOutcome {
        PersonalEpisodePublisher().makeEditions(
            feed: feed, chapters: chapters, ledger: ListeningLedger(), followedTagIDs: followed,
            requestedByUser: false, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: Kennung

    @Test("Die Kennung ist fest: auf jedem Gerät, in jeder Sprache und in jeder Fassung dieselbe")
    func deterministicID() {
        #expect(TrendingFeed.id == SmartFeedID(stable: "podcastai|smartfeed|trending"))
        // Festgeschrieben: Ändert sich der Schlüssel oder der Hash, legte
        // eine neue Fassung neben dem alten „Angesagt“ ein zweites an.
        #expect(TrendingFeed.id.rawValue == "38fc909e8005e7ed532a4d4e1df7acb1")

        let german = TrendingFeed.makeFeed(title: "Angesagt", tagIDs: [euAct], createdAt: Date(timeIntervalSince1970: 0))
        let english = TrendingFeed.makeFeed(title: "Trending", tagIDs: [chips], createdAt: Date())
        #expect(german.id == english.id)
        #expect(german.followsTrends && english.followsTrends)
        #expect(german.matchMode == .any)
        #expect(german.editionMode.budget == MediaDuration(minutes: 20))
        #expect(german.publicationPolicy.isAutomatic, "„Angesagt“ folgt derselben Automatik wie jedes Update")

        let own = SmartPodcastFeed(title: "Angesagt", topicIDs: [euAct])
        #expect(!own.followsTrends, "Ein eigenes Update mit demselben Namen ist nicht „Angesagt“")
    }

    // MARK: Tags aus den Trends

    @Test("Die Tags folgen den Trends: in ihrer Reihenfolge, jedes einmal, höchstens fünf")
    func tagsFollowTrends() {
        let ids = (1...7).map { InterestID(rawValue: "trend-\($0)") }
        let entries = [trending(detected(ids[0]), chapters: 12), trending(followed(ids[1]), chapters: 9),
                       trending(detected(ids[0]), chapters: 9)]
            + ids[2...].map { trending(detected($0)) }
        #expect(TrendingFeed.tagIDs(from: entries) == [ids[0], ids[1], ids[2], ids[3], ids[4]])
        #expect(TrendingFeed.tagIDs(from: [trending(detected(chips)), trending(followed(euAct))]) == [chips, euAct])
    }

    @Test("Tags mit Minus bleiben draußen, erkannte Tags ohne Bewertung nicht")
    func minusTagsExcluded() {
        #expect(TrendingFeed.isUnfollowed(unfollowed(euAct)))
        #expect(!TrendingFeed.isUnfollowed(detected(euAct)))
        #expect(!TrendingFeed.isUnfollowed(followed(euAct)))

        let entries = [trending(unfollowed(euAct)), trending(detected(chips)), trending(followed(privacy))]
        #expect(TrendingFeed.tagIDs(from: entries) == [chips, privacy])

        // Kommt das Minus über iCloud, bevor sich die Trends hier ändern,
        // fehlt das Tag trotzdem in der nächsten Ausgabe.
        let feed = trendingFeed([euAct, chips])
        let now = [unfollowed(euAct), detected(chips)]
        #expect(TrendingFeed.editionTagIDs(of: feed, tags: now) == [chips])
        #expect(TrendingFeed.editionTagIDs(of: feed, tags: [followed(euAct), detected(chips)]) == [euAct, chips])

        var edition = feed
        edition.topicIDs = TrendingFeed.editionTagIDs(of: feed, tags: now)
        let outcome = editions(edition, [chapter(media: "eu", tags: [euAct]), chapter(media: "chip", tags: [chips])])
        guard case .published(let run) = outcome else {
            Issue.record("Keine Ausgabe: \(outcome)")
            return
        }
        let media = Set(run.parts.flatMap { $0.segments.map(\.mediaVersionID.rawValue) })
        #expect(media == ["chip"], "Ein Kapitel nur mit dem Tag mit Minus kam in die Ausgabe")
    }

    // MARK: Ohne Trends

    @Test("Ohne Trends keine neue Ausgabe, auch nicht aus den gefolgten Tags")
    func emptyTrendsBuildNothing() {
        #expect(TrendingFeed.tagIDs(from: []).isEmpty)
        #expect(TrendingFeed.tagIDs(from: [trending(unfollowed(euAct))]).isEmpty)

        let empty = trendingFeed([])
        #expect(empty.searchTags(followed: [privacy]).isEmpty)
        let own = SmartPodcastFeed(title: "Mein Update", topicIDs: [])
        #expect(own.searchTags(followed: [privacy]) == [privacy], "Ein eigenes Update ohne Tags nimmt die gefolgten")

        let chapters = [chapter(media: "ds", tags: [privacy]), chapter(media: "eu", tags: [euAct])]
        guard case .noNewMaterial(let count) = editions(empty, chapters, followed: [privacy]) else {
            Issue.record("„Angesagt“ ohne Trends hat eine Ausgabe gebaut")
            return
        }
        #expect(count == 0)

        let stats = SmartFeedStatistics.compute(
            feed: empty, chapters: chapters, editions: [], ledger: ListeningLedger(), followedTagIDs: [privacy])
        #expect(stats.tags.isEmpty)
        #expect(stats.total == 0)

        // Mit einem angesagten Tag entsteht eine Ausgabe, nur aus seinen Kapiteln.
        guard case .published(let run) = editions(trendingFeed([euAct]), chapters, followed: [privacy]) else {
            Issue.record("Mit einem angesagten Tag entstand keine Ausgabe")
            return
        }
        #expect(Set(run.parts.flatMap { $0.segments.map(\.mediaVersionID.rawValue) }) == ["eu"])
        #expect(run.parts.allSatisfy { $0.feedID == TrendingFeed.id })
    }

    // MARK: Abgleichen

    @Test("Anlegen nur einmal von selbst und nur mit Trends")
    func createOnceWithTrends() {
        #expect(TrendingFeed.reconcile(existing: nil, desired: [], lastApplied: nil, decided: false) == .none)
        #expect(TrendingFeed.reconcile(existing: nil, desired: [euAct], lastApplied: nil, decided: false)
                == .create([euAct]))
        // Ausgeschaltet oder schon einmal angelegt: nicht wieder von selbst.
        #expect(TrendingFeed.reconcile(existing: nil, desired: [euAct], lastApplied: nil, decided: true) == .none)
        #expect(TrendingFeed.reconcile(existing: nil, desired: [euAct], lastApplied: [chips], decided: true) == .none)
    }

    @Test("Ändern sich die Trends, bekommt das Update die neuen Tags; ohne Trends leere")
    func updateWhenTrendsChange() {
        let feed = trendingFeed([euAct])
        #expect(TrendingFeed.reconcile(existing: feed, desired: [euAct, chips], lastApplied: [euAct], decided: true)
                == .update([euAct, chips]))
        #expect(TrendingFeed.reconcile(existing: feed, desired: [], lastApplied: [euAct], decided: true)
                == .update([]))
        // Dieselben Tags in anderer Reihenfolge sind keine Änderung.
        #expect(TrendingFeed.reconcile(
            existing: trendingFeed([euAct, chips]), desired: [chips, euAct], lastApplied: nil, decided: true) == .none)
        // Ein Gerät, das noch nie geschrieben hat, übernimmt seine Trends.
        #expect(TrendingFeed.reconcile(existing: feed, desired: [chips], lastApplied: nil, decided: true)
                == .update([chips]))
    }

    @Test("Zwei Geräte mit verschiedenen Trends schreiben sich nicht abwechselnd um")
    func noPingPongBetweenDevices() {
        // Gerät A schrieb [KI-Verordnung, Chips]. Gerät B zählt nur
        // KI-Verordnung, hat das zuletzt selbst geschrieben und seither
        // keine neuen Trends: Es lässt den Stand von A stehen.
        let fromA = trendingFeed([euAct, chips])
        #expect(TrendingFeed.reconcile(existing: fromA, desired: [euAct], lastApplied: [euAct], decided: true) == .none)
        // Ändern sich die Trends auf B, schreibt B.
        #expect(TrendingFeed.reconcile(existing: fromA, desired: [privacy], lastApplied: [euAct], decided: true)
                == .update([privacy]))
    }

    // MARK: Zwei Geräte legen gleichzeitig an

    @Test("Legen zwei Geräte „Angesagt“ gleichzeitig an, bleibt nach dem Abgleich eines")
    func twoDevicesKeepOne() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let own = SmartPodcastFeed(title: "Datenschutz", topicIDs: [privacy])
        try await store.save(smartFeeds: [own, trendingFeed([euAct])])
        // Die Zeile des anderen Geräts: dieselbe Kennung, später angelegt,
        // in einer anderen Sprache und mit seinen Trends.
        let other = TrendingFeed.makeFeed(title: "Trending", tagIDs: [chips])
        try await store.insertSmartFeedCopyForTesting(other, createdAt: Date().addingTimeInterval(60))
        #expect(try await store.rowCountForTesting(StoredSmartFeed.self) == 3)
        // Schon vor dem Bereinigen erscheint „Angesagt“ nur einmal.
        #expect(try await store.smartFeeds().filter(\.followsTrends).count == 1)

        try await store.removeDuplicates()

        #expect(try await store.rowCountForTesting(StoredSmartFeed.self) == 2)
        let feeds = try await store.smartFeeds()
        let ids: Set<SmartFeedID> = Set(feeds.map(\.id))
        #expect(ids == [own.id, TrendingFeed.id])
        #expect(feeds.count == 2)
        // Behalten wird die früher angelegte Zeile, auf jedem Gerät dieselbe.
        #expect(feeds.first(where: \.followsTrends)?.title == "Angesagt")
    }

    @Test("Ausschalten löscht das Update mit seinen Ausgaben, die anderen Updates bleiben")
    func turningOffRemovesEditions() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let own = SmartPodcastFeed(title: "Datenschutz", topicIDs: [privacy])
        let feed = trendingFeed([euAct])
        try await store.save(smartFeeds: [own, feed])
        guard case .published(let trendingRun) = editions(feed, [chapter(media: "eu", tags: [euAct])]),
              case .published(let ownRun) = editions(own, [chapter(media: "ds", tags: [privacy])]) else {
            Issue.record("Keine Ausgaben zum Löschen")
            return
        }
        try await store.save(editions: trendingRun.parts, forFeed: TrendingFeed.id)
        try await store.save(editions: ownRun.parts, forFeed: own.id)

        // Derselbe Weg wie `AppModel.removeSmartFeed`.
        try await store.save(smartFeeds: [own])
        try await store.save(editions: [], forFeed: TrendingFeed.id)

        #expect(try await store.smartFeeds().map(\.id) == [own.id])
        let stored = try await store.editions()
        #expect(stored[TrendingFeed.id] == nil)
        #expect(stored[own.id]?.map(\.id) == ownRun.parts.map(\.id))
    }
}

extension LibraryStore {
    /// Nur für Tests: die Zeile eines Updates, wie sie der Abgleich von
    /// einem anderen Gerät bringt, ohne Prüfung auf Doppelte.
    func insertSmartFeedCopyForTesting(_ feed: SmartPodcastFeed, createdAt: Date) throws {
        let row = StoredSmartFeed(identifier: feed.id.rawValue, title: feed.title, payload: try Self.encoder.encode(feed))
        row.createdAt = createdAt
        modelContext.insert(row)
        try modelContext.save()
    }
}
