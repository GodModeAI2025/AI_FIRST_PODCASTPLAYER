//
//  TagFoundationTests.swift
//
//  Das Fundament der Tags aus 0.10: Schlüssel für Schreibweisen,
//  Kennungen der Kapitel-Tags, Zusammenlegen mit Umschreiben der Verweise
//  und die Löschregeln.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIKnowledge

@Suite("Tags: Schlüssel")
struct TagNormalizerTests {

    @Test("USA, US, Vereinigte Staaten und United States sind ein Land")
    func unitedStates() {
        for label in ["USA", "US", "U.S.A.", "Vereinigte Staaten", "United States", "vereinigte staaten",
                      "Vereinigte Staaten von Amerika"] {
            #expect(TagNormalizer.key(for: label) == "region:US", "\(label)")
        }
    }

    @Test("UK, Großbritannien und Vereinigtes Königreich sind ein Land, die EU ist eine Region")
    func otherRegions() {
        for label in ["UK", "Großbritannien", "Grossbritannien", "Vereinigtes Königreich", "United Kingdom"] {
            #expect(TagNormalizer.key(for: label) == "region:GB", "\(label)")
        }
        for label in ["EU", "Europäische Union", "European Union"] {
            #expect(TagNormalizer.key(for: label) == "region:EU", "\(label)")
        }
        #expect(TagNormalizer.key(for: "Deutschland") == "region:DE")
        #expect(TagNormalizer.key(for: "Germany") == "region:DE")
        // „Island“ ist auf Englisch eine Insel, kein Land.
        #expect(TagNormalizer.key(for: "island") == "island")
    }

    @Test("Leerzeichen, Bindestriche und Großschreibung zählen nicht")
    func spacing() {
        let key = TagNormalizer.key(for: "iOS 27")
        #expect(key == "ios27")
        for label in ["ios27", "iOS-27", "IOS 27", " iOS  27 "] {
            #expect(TagNormalizer.key(for: label) == key, "\(label)")
        }
        #expect(TagNormalizer.key(for: "E-Mail") == TagNormalizer.key(for: "email"))
        #expect(TagNormalizer.key(for: "  ").isEmpty)
        #expect(TagNormalizer.key(for: "?!").isEmpty)
    }

    @Test("Umlaute, Akzente und ß zählen nicht")
    func umlauts() {
        let key = TagNormalizer.key(for: "Überwachung")
        #expect(key == "uberwachung")
        #expect(TagNormalizer.key(for: "überwachung") == key)
        #expect(TagNormalizer.key(for: "Uberwachung") == key)
        #expect(TagNormalizer.key(for: "Straße") == TagNormalizer.key(for: "Strasse"))
        #expect(TagNormalizer.key(for: "Café") == TagNormalizer.key(for: "cafe"))
    }

    @Test("Mehrzahl und Beugung fallen über das Lemma zusammen",
          .enabled(if: TagNormalizer.lemmaAvailable))
    func plurals() {
        #expect(TagNormalizer.key(for: "Batterien") == TagNormalizer.key(for: "Batterie"))
        #expect(TagNormalizer.key(for: "Podcasts") == TagNormalizer.key(for: "Podcast"))
        #expect(TagNormalizer.key(for: "Elektroautos") == TagNormalizer.key(for: "Elektroauto"))
        #expect(TagNormalizer.key(for: "Kriege") == TagNormalizer.key(for: "Krieg"))
        #expect(TagNormalizer.key(for: "electric cars") == TagNormalizer.key(for: "electric car"))
        // Bewusst: „Daten“ wird nicht zu „Datum“.
        #expect(TagNormalizer.key(for: "Daten") == "daten")
    }

    @Test("Aliasse verbinden Schreibweisen, die der Schlüssel nicht verbindet")
    func aliases() {
        let tag = PodcastAICore.Tag(id: InterestID(rawValue: "ki"), label: "Künstliche Intelligenz",
                      normalizedKey: TagNormalizer.key(for: "Künstliche Intelligenz"),
                      stance: .follow, origin: .confirmedByUser, aliases: ["KI", "AI"])
        #expect(TagNormalizer.matches("ki", tag: tag))
        #expect(TagNormalizer.matches("künstliche Intelligenz", tag: tag))
        #expect(!TagNormalizer.matches("Datenschutz", tag: tag))
        #expect(TagNormalizer.resolve("AI", in: [tag])?.id == tag.id)
    }

    @Test("Neue Tags aus dem Inhalt: keine heiklen Themen, keine Sätze, Kennung aus dem Schlüssel")
    func detectedTags() throws {
        #expect(TagNormalizer.makeDetectedTag(label: "Wahlen") == nil)
        #expect(TagNormalizer.makeDetectedTag(label: "Religion") == nil)
        #expect(TagNormalizer.makeDetectedTag(label: "Was bringt iOS 27?") == nil)
        let tag = try #require(TagNormalizer.makeDetectedTag(label: " Datenschutz "))
        #expect(tag.label == "Datenschutz")
        #expect(tag.stance == .neutral)
        #expect(tag.origin == .detected)
        #expect(tag.id == PodcastAICore.Tag.stableID(forKey: TagNormalizer.key(for: "Datenschutz")))
        #expect(!tag.isFollowed)
    }
}

@Suite("Tags: Profil")
struct TagProfileTests {

    @Test("Nur gefolgte Tags treiben Relevanz und Themen-Updates")
    func followedOnly() {
        let confirmed = Interest(label: "Datenschutz")
        var unfollowed = Interest(label: "Robotik")
        unfollowed.stance = .neutral
        let detected = Interest(label: "Batterie", origin: .detected, stance: .neutral)
        var plussed = Interest(label: "Elektroauto", origin: .detected, stance: .neutral)
        plussed.stance = .follow
        let profile = InterestProfile(interests: [confirmed, unfollowed, detected, plussed])
        #expect(Set(profile.topics.map(\.label)) == ["Datenschutz", "Elektroauto"])
        #expect(Set(profile.publicationDrivers().map(\.label)) == ["Datenschutz", "Elektroauto"])
        #expect(profile.suggested.isEmpty)
        #expect(profile.tags.count == 4)
    }

    @Test("Ein Interesse ohne Tag-Felder lässt sich weiter lesen")
    func decodesLegacyInterest() throws {
        let json = #"{"id":"x","label":"Datenschutz","kind":"topic","origin":"confirmedByUser","keywords":[],"createdAt":0}"#
        let interest = try JSONDecoder().decode(Interest.self, from: Data(json.utf8))
        #expect(interest.stance == .follow)
        #expect(interest.normalizedKey.isEmpty)
        #expect(interest.firstSeenAt == nil)
    }
}

@Suite("Tags: Speicher")
struct TagStoreTests {

    let sourceID = SourceID(stable: "quelle")
    let episodeID = EpisodeID(stable: "folge")
    let audio = URL(string: "https://example.com/folge.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }
    let published = Date(timeIntervalSince1970: 1_790_000_000)

    func store() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    /// Mit Quelle, Folge, Transkript und, wenn `withTags`, den Tags, auf die
    /// die Kapitel-Tags der Tests zeigen. Der Store nimmt nur Kapitel-Tags
    /// an, deren Tag er kennt (Regel 3).
    func seededStore(withTags: Bool = true) async throws -> LibraryStore {
        let store = try store()
        if withTags {
            let created = Date(timeIntervalSince1970: 1_000)
            for (identifier, label, key) in [("ds", "Datenschutz", "datenschutz"), ("us", "USA", "region:US"),
                                             ("robotik", "Robotik", "robotik"), ("ki", "KI", "ki")] {
                try await store.insertInterestRowForTesting(
                    identifier: identifier, label: label, createdAt: created, normalizedKey: key)
            }
        }
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(episodes: [Episode(
            id: episodeID, sourceID: sourceID, title: "Folge", publishedAt: published, audioURL: audio)],
            forSource: sourceID)
        let range = MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 60_000))
        let transcript = Transcript(
            id: TranscriptID(stable: "t1"), mediaVersionID: mediaID, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE",
            segments: [TranscriptSegment(id: SegmentID(stable: "s1"), range: range, text: "Hallo")],
            analyzedRanges: IntervalSet(range))
        try await store.save(
            transcript: transcript,
            media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio, localRelativePath: "x"),
            forEpisode: episodeID)
        return store
    }

    func chapterTag(
        _ key: String, interest: InterestID, start: Int = 0, createdAt: Date = Date(),
        revision: Revision = .initial, episode: EpisodeID? = nil, media: MediaVersionID? = nil,
        source: SourceID? = nil, publishedAt: Date? = nil
    ) -> ChapterTag {
        ChapterTag(
            episodeID: episode ?? episodeID, mediaVersionID: media ?? mediaID,
            chapterStartMs: start, chapterEndMs: start + 300_000,
            interestID: interest, normalizedKey: key, confidence: 0.8, matchedKnown: true,
            sourceID: source ?? sourceID, publishedAt: publishedAt ?? published,
            createdAt: createdAt, transcriptRevision: revision)
    }

    @Test("Die Kennung eines Kapitel-Tags ist auf jedem Gerät dieselbe")
    func deterministicIdentifier() {
        let a = chapterTag("region:US", interest: InterestID(rawValue: "a"), start: 120_000,
                           createdAt: Date(timeIntervalSince1970: 1))
        let b = chapterTag("region:US", interest: InterestID(rawValue: "b"), start: 120_000,
                           createdAt: Date(timeIntervalSince1970: 2))
        #expect(a.id == b.id)
        #expect(a.id == ChapterTag.identifier(mediaVersionID: mediaID, chapterStartMs: 120_000,
                                              normalizedKey: "region:US"))
        #expect(a.id != chapterTag("region:US", interest: a.interestID, start: 0).id)
        #expect(a.id != chapterTag("region:GB", interest: a.interestID, start: 120_000).id)
        // Fester Wert: ändert sich die Rechnung, passen die Kennungen zweier
        // Versionen nicht mehr zusammen.
        #expect(a.id.rawValue == StableDigest.hex(of: "chaptertag|\(mediaID.rawValue)|120000|region:US"))
    }

    @Test("Ein neues Interesse bekommt seinen Schlüssel, eine neue Bezeichnung einen neuen")
    func upsertComputesKey() async throws {
        let store = try store()
        var interest = Interest(label: "Vereinigte Staaten")
        try await store.upsert(interest: interest)
        #expect(try await store.tags().first?.normalizedKey == "region:US")
        interest.label = "iOS 27"
        try await store.upsert(interest: interest)
        #expect(try await store.tags().first?.normalizedKey == "ios27")
        try await store.setStance(.neutral, forTag: interest.id)
        #expect(try await store.tags().first?.stance == .neutral)
        #expect(try await store.interestProfile(learningEnabled: false).topics.isEmpty)
    }

    @Test("Umbenennen über die Oberfläche: der Wert aus dem Profil trägt den alten Schlüssel, gespeichert wird der neue")
    func renameFromProfileSnapshot() async throws {
        let store = try await seededStore(withTags: false)
        try await store.upsert(interest: Interest(label: "Vereinigte Staaten"))
        var loaded = try #require(try await store.interestProfile(learningEnabled: false).interests.first)
        #expect(loaded.normalizedKey == "region:US")
        #expect(try await store.save(
            chapterTags: [chapterTag("region:US", interest: loaded.id, start: 60_000)],
            forEpisode: episodeID, transcriptRevision: .initial))

        loaded.label = "iOS 27"
        try await store.upsert(interest: loaded)
        #expect(try await store.tags().first?.normalizedKey == "ios27")
        let moved = try await store.chapterTags(forEpisode: episodeID)
        #expect(moved.map(\.normalizedKey) == ["ios27"])
        #expect(moved.first?.id == ChapterTag.identifier(mediaVersionID: mediaID, chapterStartMs: 60_000,
                                                         normalizedKey: "ios27"))

        // Gleiche Bezeichnung, anderer Schlüssel im Wert: der gespeicherte bleibt.
        loaded.normalizedKey = "etwas anderes"
        try await store.upsert(interest: loaded)
        #expect(try await store.tags().first?.normalizedKey == "ios27")
    }

    @Test("Ein Merkzeichen ohne Quelle neben einer lebenden Folge nimmt ihr die Kapitel-Tags nicht")
    func orphanedTombstoneKeepsLiveTags() async throws {
        let store = try await seededStore()
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: InterestID(rawValue: "ds"))],
            forEpisode: episodeID, transcriptRevision: .initial))
        try await store.insertEpisodeCopyForTesting(
            Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio),
            removedAt: Date(timeIntervalSince1970: 1_000), withoutSource: true)
        try await store.removeDuplicates()
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 1)
    }

    @Test("Beim Laden werden alte Interessen zu Tags, gleiche Schlüssel zu einem, und alle Verweise folgen")
    func migrationMergesAndRewrites() async throws {
        let store = try await seededStore(withTags: false)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Drei Interessen aus der Zeit vor den Tags, ohne Schlüssel.
        try await store.insertInterestRowForTesting(identifier: "usa", label: "USA", createdAt: t0,
                                                    stance: .neutral)
        try await store.insertInterestRowForTesting(identifier: "vs", label: "Vereinigte Staaten",
                                                    createdAt: t0.addingTimeInterval(60), keywords: ["Amerika"])
        try await store.insertInterestRowForTesting(identifier: "ds", label: "Datenschutz",
                                                    createdAt: t0.addingTimeInterval(120))
        let usa = InterestID(rawValue: "usa"), vs = InterestID(rawValue: "vs"), ds = InterestID(rawValue: "ds")

        let feed = SmartPodcastFeed(title: "Amerika", topicIDs: [vs, ds, usa])
        try await store.save(smartFeeds: [feed])

        let segment = PersonalEpisodeSegment(
            id: SegmentID(rawValue: "seg"), episodeID: episodeID, mediaVersionID: mediaID,
            transcriptRevision: .initial, evidenceIDs: [EvidenceID(rawValue: "e")],
            coreRange: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 10_000)),
            playbackRange: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 10_000)),
            virtualRange: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 10_000)),
            reason: "", topicIDs: [vs, ds], contextReplay: false,
            sourceID: sourceID, sourceTitle: "Quelle", episodeTitle: "Folge")
        let edition = PersonalEpisode(
            feedID: feed.id, policyRevision: .initial, batchKey: "k", title: "Ausgabe",
            segments: [segment], shownotes: [],
            coverage: EditionCoverage(candidateCount: 1, includedCount: 1, remaining: .zero))
        try await store.save(editions: [edition], forFeed: feed.id)

        try await store.save(highlights: [Highlight(evidenceID: EvidenceID(rawValue: "e"), interestIDs: [vs])])

        #expect(try await store.save(
            chapterTags: [chapterTag("region:US", interest: vs)], forEpisode: episodeID,
            transcriptRevision: .initial))

        try await store.removeDuplicates()

        let tags = try await store.tags()
        #expect(tags.count == 2)
        let merged = try #require(tags.first { $0.id == usa })
        #expect(merged.normalizedKey == "region:US")
        #expect(merged.label == "USA")
        #expect(merged.aliases.contains("Vereinigte Staaten"))
        #expect(merged.aliases.contains("Amerika"))
        // Einer der beiden wurde verfolgt, also auch das zusammengelegte.
        #expect(merged.stance == .follow)
        #expect(merged.firstSeenAt != nil)
        #expect(tags.first { $0.id == ds }?.normalizedKey == "datenschutz")

        #expect(try await store.smartFeeds().first?.topicIDs == [usa, ds])
        let rewritten = try #require(try await store.editions()[feed.id]?.first)
        #expect(rewritten.id == edition.id)
        #expect(rewritten.manifestHash == edition.manifestHash)
        #expect(rewritten.segments.first?.topicIDs == [usa, ds])
        #expect(try await store.highlights().first?.interestIDs == [usa])
        #expect(try await store.chapterTags(forEpisode: episodeID).map(\.interestID) == [usa])

        // Ein zweites Laden ändert nichts mehr.
        try await store.removeDuplicates()
        #expect(try await store.tags().count == 2)
        #expect(try await store.smartFeeds().first?.topicIDs == [usa, ds])
    }

    @Test("Zwei Geräte legen dasselbe Tag an: es bleibt eines, auf beiden dasselbe")
    func parallelTagsFromTwoDevices() async throws {
        let store = try await seededStore(withTags: false)
        // Gerät A erkennt das Tag, Gerät B hatte es vorher unter anderer
        // Kennung angelegt. Die ältere Zeile bleibt.
        let detected = try #require(try await store.addDetectedTag(label: "Elektroautos"))
        try await store.insertInterestRowForTesting(
            identifier: "anderes-geraet", label: "Elektroauto",
            createdAt: Date(timeIntervalSince1970: 1_000), stance: .neutral, origin: .detected)
        // Dieselbe Kennung zweimal, wie nach dem Abgleich der stabilen Kennung.
        try await store.insertInterestRowForTesting(
            identifier: detected.id.rawValue, label: detected.label,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000),
            normalizedKey: detected.normalizedKey, stance: .neutral, origin: .detected)
        #expect(try await store.save(
            chapterTags: [chapterTag(detected.normalizedKey, interest: detected.id)],
            forEpisode: episodeID, transcriptRevision: .initial))

        try await store.removeDuplicates()

        let tags = try await store.tags()
        #expect(tags.map(\.id) == [InterestID(rawValue: "anderes-geraet")])
        #expect(tags.first?.stance == .neutral)
        #expect(try await store.rowCountForTesting(StoredInterest.self) == 1)
        #expect(try await store.chapterTags(forEpisode: episodeID).first?.interestID
                == InterestID(rawValue: "anderes-geraet"))
        // Dasselbe Tag noch einmal erkannt: kein neues.
        #expect(try await store.addDetectedTag(label: "Elektroauto")?.id == InterestID(rawValue: "anderes-geraet"))
        #expect(try await store.addDetectedTag(label: "Wahlen") == nil)
        #expect(try await store.rowCountForTesting(StoredInterest.self) == 1)
    }

    @Test("Kapitel-Tags von zwei Geräten werden zu einer Zeile")
    func chapterTagDuplicates() async throws {
        let store = try await seededStore()
        let interest = InterestID(rawValue: "ds")
        let first = chapterTag("datenschutz", interest: interest, start: 60_000,
                               createdAt: Date(timeIntervalSince1970: 100))
        let second = chapterTag("datenschutz", interest: interest, start: 60_000,
                                createdAt: Date(timeIntervalSince1970: 200))
        try await store.insertChapterTagCopyForTesting(first)
        try await store.insertChapterTagCopyForTesting(second)
        #expect(try await store.rowCountForTesting(StoredChapterTag.self) == 2)
        // Lesen zeigt jede Kennung einmal, auch vor dem Bereinigen.
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 1)

        try await store.removeDuplicates()
        #expect(try await store.rowCountForTesting(StoredChapterTag.self) == 1)
        #expect(try await store.chapterTags(forEpisode: episodeID).first?.createdAt == first.createdAt)
    }

    @Test("Audio entfernen lässt Kapitel-Tags stehen, Folge löschen nimmt sie mit")
    func deletionRules() async throws {
        let store = try await seededStore()
        let interest = InterestID(rawValue: "ds")
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: interest),
                          chapterTag("region:US", interest: InterestID(rawValue: "us"), start: 300_000)],
            forEpisode: episodeID, transcriptRevision: .initial))

        try await store.markAudioRemoved(try await store.mediaVersionIDs(forEpisode: episodeID))
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 2)

        _ = try await store.removeEpisode(episodeID)
        #expect(try await store.rowCountForTesting(StoredChapterTag.self) == 0)
        // Eine späte Einordnung schreibt in die gelöschte Folge nichts mehr.
        #expect(try await !store.save(
            chapterTags: [chapterTag("datenschutz", interest: interest)],
            forEpisode: episodeID, transcriptRevision: .initial))
        // Und was ein anderes Gerät noch geschickt hat, räumt das Bereinigen weg.
        try await store.insertChapterTagCopyForTesting(chapterTag("datenschutz", interest: interest))
        try await store.removeDuplicates()
        #expect(try await store.rowCountForTesting(StoredChapterTag.self) == 0)
    }

    @Test("Abbestellen entfernt Kapitel-Tags der Quelle, auch ohne angekommene Folge")
    func removingSource() async throws {
        let store = try await seededStore()
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: InterestID(rawValue: "ds"))],
            forEpisode: episodeID, transcriptRevision: .initial))
        try await store.insertChapterTagCopyForTesting(chapterTag(
            "datenschutz", interest: InterestID(rawValue: "ds"),
            episode: EpisodeID(stable: "noch unterwegs"), media: MediaVersionID(stable: "m2")))
        _ = try await store.removeSource(sourceID)
        #expect(try await store.rowCountForTesting(StoredChapterTag.self) == 0)
    }

    @Test("Eine neuere Fassung des Transkripts ersetzt, eine ältere schreibt nichts")
    func revisions() async throws {
        let store = try await seededStore()
        let interest = InterestID(rawValue: "ds")
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: interest, start: 0),
                          chapterTag("robotik", interest: InterestID(rawValue: "robotik"), start: 0)],
            forEpisode: episodeID, transcriptRevision: Revision(2)))
        let ki = InterestID(rawValue: "ki")
        #expect(try await !store.save(
            chapterTags: [chapterTag("ki", interest: ki)],
            forEpisode: episodeID, transcriptRevision: Revision(1)))
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 2)
        #expect(try await store.save(
            chapterTags: [chapterTag("ki", interest: ki)],
            forEpisode: episodeID, transcriptRevision: Revision(3)))
        let tags = try await store.chapterTags(forEpisode: episodeID)
        #expect(tags.map(\.normalizedKey) == ["ki"])
        #expect(tags.first?.transcriptRevision == Revision(3))
    }

    @Test("Abfragen nach Tag und Zeitraum, Zählung je Tag und Quelle")
    func queriesAndCounts() async throws {
        let store = try await seededStore()
        let otherSource = SourceID(stable: "andere")
        let otherEpisode = EpisodeID(stable: "andere folge")
        let otherMedia = MediaVersionID(stable: "andere fassung")
        let interest = InterestID(rawValue: "ds")
        let day: TimeInterval = 86_400
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: interest, start: 0),
                          chapterTag("datenschutz", interest: interest, start: 300_000),
                          chapterTag("robotik", interest: InterestID(rawValue: "robotik"), start: 300_000)],
            forEpisode: episodeID, transcriptRevision: .initial))
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: interest, episode: otherEpisode,
                                     media: otherMedia, source: otherSource,
                                     publishedAt: published.addingTimeInterval(-30 * day))],
            forEpisode: otherEpisode, transcriptRevision: .initial))

        #expect(try await store.chapterTags(forKey: "datenschutz").count == 3)
        let week = try await store.chapterTags(publishedFrom: published.addingTimeInterval(-7 * day),
                                               to: published.addingTimeInterval(day))
        #expect(week.count == 3)
        let counts = try await store.chapterTagCounts(publishedFrom: published.addingTimeInterval(-60 * day),
                                                      to: published.addingTimeInterval(day))
        #expect(counts.first == ChapterTagCount(normalizedKey: "datenschutz", sourceID: sourceID, chapterCount: 2))
        #expect(counts.contains(ChapterTagCount(normalizedKey: "datenschutz", sourceID: otherSource, chapterCount: 1)))
        #expect(counts.contains(ChapterTagCount(normalizedKey: "robotik", sourceID: sourceID, chapterCount: 1)))
    }

    @Test("Regel 3: Kapitel-Tags nur zu bekannten Tags, den Schlüssel bestimmt das Tag")
    func chapterTagsNeedKnownTag() async throws {
        let store = try await seededStore()
        #expect(try await store.save(
            chapterTags: [chapterTag("frei erfunden", interest: InterestID(rawValue: "ds"), start: 0),
                          chapterTag("unbekannt", interest: InterestID(rawValue: "gibt es nicht"), start: 60_000)],
            forEpisode: episodeID, transcriptRevision: .initial))
        let saved = try await store.chapterTags(forEpisode: episodeID)
        #expect(saved.map(\.normalizedKey) == ["datenschutz"])
        #expect(saved.first?.id == ChapterTag.identifier(mediaVersionID: mediaID, chapterStartMs: 0,
                                                         normalizedKey: "datenschutz"))
    }

    @Test("Eine neue Medienfassung zählt ihre Revisionen neu und ersetzt die alte")
    func newMediaVersionReplaces() async throws {
        let store = try await seededStore()
        let ds = InterestID(rawValue: "ds")
        #expect(try await store.save(
            chapterTags: [chapterTag("datenschutz", interest: ds)],
            forEpisode: episodeID, transcriptRevision: Revision(3)))
        let newMedia = MediaVersionID(stable: "neue fassung")
        #expect(try await store.save(
            chapterTags: [chapterTag("robotik", interest: InterestID(rawValue: "robotik"),
                                     revision: Revision(1), media: newMedia)],
            forEpisode: episodeID, transcriptRevision: Revision(1)))
        let saved = try await store.chapterTags(forEpisode: episodeID)
        #expect(saved.map(\.mediaVersionID) == [newMedia])
        // Dieselbe Fassung mit älterer Revision schreibt weiter nichts.
        #expect(try await !store.save(
            chapterTags: [chapterTag("ki", interest: InterestID(rawValue: "ki"), media: newMedia)],
            forEpisode: episodeID, transcriptRevision: .initial))
        #expect(try await store.chapterTags(forEpisode: episodeID).map(\.normalizedKey) == ["robotik"])
    }

    @Test("Nach dem Abgleich gilt je Fassung nur die neueste Revision")
    func syncKeepsNewestRevision() async throws {
        let store = try await seededStore()
        // Gerät A hat nach Revision 1 eingeordnet, Gerät B nach Revision 2.
        try await store.insertChapterTagCopyForTesting(chapterTag(
            "datenschutz", interest: InterestID(rawValue: "ds"), start: 0,
            createdAt: Date(timeIntervalSince1970: 100), revision: Revision(1)))
        try await store.insertChapterTagCopyForTesting(chapterTag(
            "datenschutz", interest: InterestID(rawValue: "ds"), start: 0,
            createdAt: Date(timeIntervalSince1970: 200), revision: Revision(2)))
        try await store.insertChapterTagCopyForTesting(chapterTag(
            "robotik", interest: InterestID(rawValue: "robotik"), start: 300_000,
            createdAt: Date(timeIntervalSince1970: 100), revision: Revision(1)))
        try await store.removeDuplicates()
        let tags = try await store.chapterTags(forEpisode: episodeID)
        #expect(tags.map(\.normalizedKey) == ["datenschutz"])
        #expect(tags.first?.transcriptRevision == Revision(2))
        #expect(try await store.rowCountForTesting(StoredChapterTag.self) == 1)
    }

    @Test("Ein Vorschlag macht ein erkanntes Tag beim Zusammenlegen nicht zu einem gefolgten")
    func suggestionDoesNotFollowDetected() async throws {
        let store = try await seededStore(withTags: false)
        try await store.insertInterestRowForTesting(
            identifier: "vorschlag", label: "Elektroauto", createdAt: Date(timeIntervalSince1970: 1_000),
            stance: .follow, origin: .suggestedBySystem)
        let detected = try #require(try await store.addDetectedTag(label: "Elektroautos"))
        #expect(detected.id != InterestID(rawValue: "vorschlag"))
        try await store.removeDuplicates()
        let tags = try await store.tags()
        #expect(tags.count == 1)
        #expect(tags.first?.origin == .detected)
        #expect(tags.first?.stance == .neutral)
        let profile = try await store.interestProfile(learningEnabled: false)
        #expect(profile.topics.isEmpty)
        #expect(profile.followed.isEmpty)
    }

    @Test("Abbestellen lässt Kapitel-Tags einer Folge stehen, die unter einer anderen Quelle lebt")
    func removingSourceKeepsLivingEpisodeElsewhere() async throws {
        let store = try await seededStore()
        let otherSource = SourceID(stable: "andere")
        let otherEpisode = EpisodeID(stable: "andere folge")
        try await store.upsert(source: Source(id: otherSource, kind: .podcastRSS, title: "Andere"))
        _ = try await store.upsert(episodes: [Episode(
            id: otherEpisode, sourceID: otherSource, title: "Andere Folge", publishedAt: published,
            audioURL: URL(string: "https://example.com/andere.mp3")!)], forSource: otherSource)
        // Das Kapitel-Tag trägt noch die alte Quelle.
        try await store.insertChapterTagCopyForTesting(chapterTag(
            "datenschutz", interest: InterestID(rawValue: "ds"),
            episode: otherEpisode, media: MediaVersionID(stable: "andere fassung")))
        _ = try await store.removeSource(sourceID)
        #expect(try await store.chapterTags(forEpisode: otherEpisode).count == 1)
    }
}
