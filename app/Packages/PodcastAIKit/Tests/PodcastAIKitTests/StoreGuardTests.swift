//
//  StoreGuardTests.swift
//  PodcastAIKitTests
//
//  Schritt 1 der Stufen-Pipeline (docs/plan-pipeline.md): der Wächter im
//  Store, der Beleg über das Geschriebene und die Vermerke für angefangenes
//  Löschen.
//
//  - Transkript und Belege entstehen in einem Schritt. Liegt für die
//    Fassung schon ein Transkript, bleibt es, und die Belege kommen aus ihm.
//  - Gelöscht, abbestellt, ohne Zeile, ohne Quelle, von einer neueren
//    Fassung mit Transkript überholt: Der Store schreibt nichts und sagt
//    warum. Eine neue Audioadresse allein hält das Transkript nicht auf.
//  - Nach einer Löschung räumt der Beleg genau das Geschriebene weg.
//  - Die Vermerke überstehen einen Neustart, und eine gerade nicht lesbare
//    Liste wird nicht überschrieben.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence

// MARK: - Bausteine

private let sourceID = SourceID(stable: "wächter-quelle")
private let episodeID = EpisodeID(stable: "wächter-folge")
private let audio = URL(string: "https://example.com/waechter.mp3")!
private var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }
private var episode: Episode { Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio) }

private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
    MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
}

private func makeStore() throws -> LibraryStore {
    LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
}

private func subscribe(_ store: LibraryStore) async throws {
    try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
    _ = try await store.upsert(episodes: [episode], forSource: sourceID)
}

/// Ein Transkript der Fassung, mit einem Segment je Text, je zehn Sekunden.
private func transcript(
    locale: String = "de_DE", texts: [String] = ["Hallo Welt", "Zweiter Satz"],
    media: MediaVersionID = mediaID, origin: TranscriptOrigin = .speechAnalysis
) -> Transcript {
    let segments = texts.enumerated().map { index, text in
        let part = range(Int64(index) * 10_000, Int64(index) * 10_000 + 9_000)
        return TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: media, range: part),
                                 range: part, text: text)
    }
    return Transcript(
        id: TranscriptID(stable: "\(media.rawValue)|\(locale)"), mediaVersionID: media, revision: .initial,
        origin: origin, locale: locale, segments: segments,
        analyzedRanges: IntervalSet(range(0, Int64(texts.count) * 10_000)))
}

private func evidence(of transcript: Transcript) -> [Evidence] {
    EvidenceRecipe.evidence(from: transcript, episodeID: episodeID, sourceID: sourceID)
}

private func media(_ id: MediaVersionID = mediaID, url: URL = audio) -> MediaVersion {
    MediaVersion(id: id, episodeID: episodeID, remoteURL: url)
}

private func rebuild(_ transcript: Transcript) -> [Evidence] {
    EvidenceRecipe.evidence(from: transcript, episodeID: episodeID, sourceID: sourceID)
}

/// Transkript und Belege hinter dem Wächter, mit eigenem Löschprotokoll.
private func commit(
    _ store: LibraryStore, _ transcript: Transcript, ledger: RemovalLedger,
    since ticket: RemovalLedger.Ticket? = nil, media: MediaVersion = media(), source: SourceID? = nil
) async throws -> CommitResult<[Evidence]> {
    try await store.commit(
        transcript: transcript, media: media, evidence: evidence(of: transcript),
        rebuild: rebuild,
        under: CommitGuard(episode: episodeID, source: source, since: ticket ?? ledger.ticket, ledger: ledger))
}

// MARK: - Transkript und Belege

@Suite("Wächter im Store: Transkript und Belege")
struct TranscriptCommitTests {

    @Test("Fassung, Transkript und Belege in einem Schritt, der Beleg nennt die neuen Zeilen")
    func writesEverythingAtOnce() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let ledger = RemovalLedger()
        let text = transcript()

        let result = try await commit(store, text, ledger: ledger)
        let (receipt, written) = try result.get()
        #expect(written == evidence(of: text))
        #expect(receipt.mediaVersionIDs == [mediaID])
        #expect(receipt.transcriptIDs == [text.id])
        #expect(Set(receipt.evidenceIDs) == Set(written.map(\.id)))
        #expect(receipt.keptTranscriptID == nil)
        #expect(try await store.transcript(forMedia: mediaID)?.segments.count == 2)
        #expect(try await store.evidence(forEpisode: episodeID).count == written.count)
        #expect(try await store.analyzedEpisodeIDs() == [episodeID])
        #expect(try await store.episodes(ids: [episodeID]).first?.currentMediaVersionID == mediaID)
    }

    @Test("Schon ein Transkript für die Fassung: es bleibt, die Belege entstehen aus ihm")
    func keepsTheStoredTranscript() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let ledger = RemovalLedger()
        let first = transcript(locale: "de_DE", texts: ["Vom anderen Gerät", "mit eigenem Text"])
        _ = try await commit(store, first, ledger: ledger).get()

        // Ein zweites Gerät mit anderer Sprache transkribiert dieselbe Datei.
        let second = transcript(locale: "en_US", texts: ["From this device", "other words", "and more"])
        let (receipt, written) = try await commit(store, second, ledger: ledger).get()
        #expect(receipt.keptTranscriptID == first.id)
        #expect(receipt.transcriptIDs.isEmpty)
        #expect(receipt.mediaVersionIDs.isEmpty)
        #expect(receipt.evidenceIDs.isEmpty, "die Belege des gespeicherten Transkripts gelten")
        #expect(written.map(\.id) == evidence(of: first).map(\.id))
        #expect(written.allSatisfy { $0.transcriptID == first.id })
        #expect(written.map(\.quotedText).joined(separator: " ").contains("anderen Gerät"))
        #expect(try await store.transcript(forMedia: mediaID)?.id == first.id)
        #expect(try await store.transcript(forMedia: mediaID)?.segments.count == 2)
    }

    @Test("Gespeichertes Transkript mit eigenen Belegen: sie bleiben, es entstehen keine zweiten")
    func keepsForeignEvidence() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let first = transcript(texts: (0..<20).map { "Satz \($0)" })
        // So kommt es von einem Gerät, das die Passagen anders schnitt: ein
        // Beleg über alles statt zweien.
        try await store.save(transcript: first, media: media(), forEpisode: episodeID)
        let whole = Evidence(
            id: Evidence.stableID(mediaVersionID: mediaID, transcriptRevision: .initial, range: range(0, 199_000)),
            mediaVersionID: mediaID, episodeID: episodeID, sourceID: sourceID, transcriptID: first.id,
            transcriptRevision: .initial, range: range(0, 199_000), quotedText: "alles")
        try await store.store(evidence: [whole])
        try #require(evidence(of: first).count == 2)

        let second = transcript(locale: "en_US", texts: ["From this device"])
        let (receipt, written) = try await commit(store, second, ledger: RemovalLedger()).get()
        #expect(receipt.keptTranscriptID == first.id)
        #expect(receipt.evidenceIDs.isEmpty)
        #expect(written.map(\.id) == [whole.id])
        #expect(try await store.evidence(forEpisode: episodeID).map(\.id) == [whole.id])
    }

    @Test("Gespeichertes Transkript ohne Belege: die Belege entstehen aus ihm")
    func rebuildsMissingEvidence() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let first = transcript(texts: ["Vom anderen Gerät", "ohne Belege"])
        try await store.save(transcript: first, media: media(), forEpisode: episodeID)

        let second = transcript(locale: "en_US", texts: ["From this device"])
        let (receipt, written) = try await commit(store, second, ledger: RemovalLedger()).get()
        #expect(receipt.keptTranscriptID == first.id)
        #expect(written.map(\.id) == evidence(of: first).map(\.id))
        #expect(Set(receipt.evidenceIDs) == Set(written.map(\.id)))
        #expect(try await store.evidence(forEpisode: episodeID).map(\.id) == written.map(\.id))
    }

    @Test("Seit dem Start gelöscht: nichts wird geschrieben")
    func refusesAfterRemoval() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let ledger = RemovalLedger()
        let ticket = ledger.ticket
        ledger.markRemoved([episodeID])

        let result = try await commit(store, transcript(), ledger: ledger, since: ticket)
        #expect(result.staleReason == .removedWhileRunning)
        #expect(throws: StaleWriteError(reason: .removedWhileRunning)) { try result.get() }
        #expect(try await store.transcript(forMedia: mediaID) == nil)
        #expect(try await store.evidence(forEpisode: episodeID).isEmpty)
    }

    @Test("Merkzeichen, fehlende Zeile, fehlende Quelle: nichts wird geschrieben")
    func refusesWithoutLiveEpisode() async throws {
        let ledger = RemovalLedger()

        let tombstoned = try makeStore()
        try await subscribe(tombstoned)
        _ = try await tombstoned.removeEpisode(episodeID)
        #expect(try await commit(tombstoned, transcript(), ledger: ledger).staleReason == .episodeRemoved)
        #expect(try await tombstoned.evidence(forEpisode: episodeID).isEmpty)

        let missing = try makeStore()
        try await missing.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        #expect(try await commit(missing, transcript(), ledger: ledger).staleReason == .episodeMissing)

        // So sieht eine Folge aus, deren Quelle ein anderes Gerät abbestellt
        // hat, bevor die Löschung ihrer eigenen Zeile ankam: keine Quellzeile.
        let abandoned = try makeStore()
        try await abandoned.insertEpisodeCopyForTesting(episode, withoutSource: true)
        #expect(try await commit(abandoned, transcript(), ledger: ledger, source: sourceID).staleReason
                == .sourceMissing)
        #expect(try await abandoned.transcript(forMedia: mediaID) == nil)

        // Ohne Angabe der Quelle gilt eine Zeile ohne Quelle als abbestellt.
        let orphan = try makeStore()
        try await orphan.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        try await orphan.insertEpisodeCopyForTesting(episode, withoutSource: true)
        #expect(try await commit(orphan, transcript(), ledger: ledger).staleReason == .sourceMissing)
        #expect(try await orphan.transcript(forMedia: mediaID) == nil)
    }

    @Test("Zeile ohne Quelle nach dem Abgleich, die Quelle besteht: geschrieben wird")
    func orphanedRowUnderLiveSourceIsWritten() async throws {
        // Ein anderes Gerät hat eine doppelte Quellzeile gelöscht, bevor die
        // umgehängte Folge hier ankam. Das nächste Bereinigen hängt sie an.
        let store = try makeStore()
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        try await store.insertEpisodeCopyForTesting(episode, withoutSource: true)
        let ledger = RemovalLedger()
        let result = try await commit(store, transcript(), ledger: ledger, source: sourceID)
        #expect(result.receipt?.transcriptIDs == [transcript().id])
        #expect(try await store.transcript(forMedia: mediaID) != nil)

        // Wurde die Quelle hier abbestellt, gilt das trotzdem.
        let ticket = ledger.ticket
        ledger.markRemoved([], source: sourceID)
        #expect(try await commit(store, transcript(), ledger: ledger, since: ticket, source: sourceID).staleReason
                == .removedWhileRunning)
    }

    @Test("Ein Merkzeichen aus einem früheren Abo hält die neue Folge nicht auf")
    func oldTombstoneWithoutSourceDoesNotBlock() async throws {
        let store = try makeStore()
        try await subscribe(store)
        // Gelöscht einen Tag vor dem Abo: aus einem früheren Abo.
        try await store.insertEpisodeCopyForTesting(
            episode, removedAt: Date(timeIntervalSinceNow: -86_400), withoutSource: true)
        let result = try await commit(store, transcript(), ledger: RemovalLedger(), source: sourceID)
        #expect(result.receipt != nil)
    }

    @Test("Ein Merkzeichen ohne Quelle, jünger als das Abo, hält die Folge auf")
    func recentTombstoneWithoutSourceBlocks() async throws {
        // Das Bereinigen hängt es an die Quelle, und dann gilt es.
        let store = try makeStore()
        try await subscribe(store)
        try await store.insertEpisodeCopyForTesting(
            episode, removedAt: Date(timeIntervalSinceNow: 60), withoutSource: true)
        #expect(try await commit(store, transcript(), ledger: RemovalLedger(), source: sourceID).staleReason
                == .episodeRemoved)
        #expect(try await store.transcript(forMedia: mediaID) == nil)
    }

    @Test("Abbestellt und neu abonniert: der alte Lauf schreibt nicht, ein neuer schon")
    func resubscribedSourceRefusesTheOldRun() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let ledger = RemovalLedger()
        let before = ledger.ticket
        ledger.markRemoved([episodeID], source: sourceID)
        _ = try await store.removeSource(sourceID)
        try await subscribe(store)

        #expect(try await commit(store, transcript(), ledger: ledger, since: before).staleReason
                == .removedWhileRunning)
        #expect(try await store.analyzedEpisodeIDs().isEmpty)
        #expect(try await commit(store, transcript(), ledger: ledger).receipt != nil)
    }

    @Test("Hat die Datei, auf die der Feed jetzt zeigt, ein Transkript, schreibt die alte nichts")
    func refusesSupersededMedia() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let ledger = RemovalLedger()
        _ = try await commit(store, transcript(), ledger: ledger).get()
        let old = URL(string: "https://example.com/alt.mp3")!
        let oldMedia = MediaVersionID(stable: old.absoluteString)
        let result = try await commit(
            store, transcript(media: oldMedia), ledger: ledger, media: media(oldMedia, url: old))
        #expect(result.staleReason == .mediaChanged)
        #expect(result.staleReason?.meansRemoved == false)
        #expect(try await store.transcript(forMedia: oldMedia) == nil)
        #expect(try await store.episodes(ids: [episodeID]).first?.currentMediaVersionID == mediaID)
    }

    @Test("Neue Audioadresse ohne Transkript: das laufende Transkript wird gespeichert wie bisher")
    func writesAfterAddressDrift() async throws {
        let store = try makeStore()
        try await subscribe(store)
        // Manche Feeds hängen bei jedem Abruf einen neuen Zeitstempel an.
        let started = URL(string: "https://example.com/waechter.mp3?t=1")!
        let startedMedia = MediaVersionID(stable: started.absoluteString)
        let result = try await commit(
            store, transcript(media: startedMedia), ledger: RemovalLedger(), media: media(startedMedia, url: started))
        #expect(result.receipt?.transcriptIDs.count == 1)
        #expect(try await store.transcript(forMedia: startedMedia) != nil)
        #expect(try await store.episodes(ids: [episodeID]).first?.currentMediaVersionID == startedMedia)
    }

    @Test("Videos: die Fassung hängt an der Adresse des Videos")
    func videoFollowsItsAddress() async throws {
        let store = try makeStore()
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Kanal"))
        let page = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10")!
        let video = Episode(id: episodeID, sourceID: sourceID, title: "Video", webPageURL: page)
        _ = try await store.upsert(episodes: [video], forSource: sourceID)
        let watch = try #require(CaptionAnalysis.captionURL(of: video))
        #expect(CaptionAnalysis.feedMediaVersionID(of: video) == CaptionAnalysis.mediaVersionID(watchURL: watch))
        #expect(CaptionAnalysis.captionURL(of: episode) == nil)

        let captions = (0..<30).map {
            SupadataCaption(text: "Satz Nummer \($0).", offsetMilliseconds: Int64($0) * 4_000,
                            durationMilliseconds: 4_200, lang: "de")
        }
        let built = try #require(CaptionAnalysis.build(
            captions: SupadataTranscript(lang: "de", availableLangs: ["de"], captions: captions),
            episodeID: episodeID, sourceID: sourceID, watchURL: watch, fallbackLocale: "de"))

        let ledger = RemovalLedger()
        let full = CommitGuard(episode: episodeID, since: ledger.ticket, ledger: ledger,
                               feedMedia: { CaptionAnalysis.feedMediaVersionID(of: $0) })
        let (receipt, written) = try await store.commit(captions: built, under: full).get()
        #expect(written == built.evidence)
        #expect(receipt.transcriptIDs == [built.transcript.id])
        #expect(try await store.transcript(forMedia: built.media.id) != nil)
    }

    @Test("Belege richten sich nach der Herkunft des Transkripts")
    func recipeFollowsOrigin() {
        // Kurze Segmente ohne Pause: Untertitel schneiden trotzdem, Ton nicht.
        let texts = (0..<12).map { "Satz \($0)." }
        let spoken = transcript(texts: texts, origin: .speechAnalysis)
        let captions = transcript(texts: texts, origin: .youTubeCaptions)
        #expect(EvidenceRecipe.passages(for: spoken) == PassageBuilder.passages(from: spoken))
        #expect(EvidenceRecipe.passages(for: captions) == CaptionAnalysis.passages(for: captions))
        #expect(EvidenceRecipe.passages(for: transcript(texts: texts, origin: .youTubeCaptionsAligned))
                == CaptionAnalysis.passages(for: captions))
    }
}

// MARK: - Fakten, Kapitel-Tags und erkannte Tags

@Suite("Wächter im Store: Fakten und Tags")
struct KnowledgeCommitTests {

    /// Eine Folge mit Transkript und Belegen, über den Wächter gespeichert.
    func analyzedStore() async throws -> (LibraryStore, [Evidence]) {
        let store = try makeStore()
        try await subscribe(store)
        let written = try await commit(store, transcript(), ledger: RemovalLedger()).get().value
        return (store, written)
    }

    func fact(_ id: String, citing evidence: EvidenceID) -> EpisodeFact {
        EpisodeFact(id: id, episodeID: episodeID, sourceID: sourceID, evidenceID: evidence,
                    mediaVersionID: mediaID, statement: "Aussage \(id)", range: range(0, 9_000), modelTier: "test")
    }

    func guardNow(_ ledger: RemovalLedger = RemovalLedger()) -> CommitGuard {
        CommitGuard(episode: episodeID, since: ledger.ticket, ledger: ledger)
    }

    @Test("Fakten brauchen ihre Belege")
    func factsNeedTheirEvidence() async throws {
        let (store, written) = try await analyzedStore()
        let evidenceID = try #require(written.first?.id)

        let receipt = try #require(try await store.commit(facts: [fact("f1", citing: evidenceID)], under: guardNow()).receipt)
        #expect(receipt.factIDs == ["f1"])
        #expect(try await store.facts(forEpisode: episodeID).map(\.id) == ["f1"])

        let missing = fact("f2", citing: EvidenceID(stable: "gibt es nicht"))
        #expect(try await store.commit(facts: [missing], under: guardNow()).staleReason == .inputChanged)
        #expect(try await store.facts(forEpisode: episodeID).map(\.id) == ["f1"], "nichts ersetzt")

        let ledger = RemovalLedger()
        let ticket = ledger.ticket
        ledger.markRemoved([episodeID])
        let late = CommitGuard(episode: episodeID, since: ticket, ledger: ledger)
        #expect(try await store.commit(facts: [], under: late).staleReason == .removedWhileRunning)
        #expect(try await store.facts(forEpisode: episodeID).map(\.id) == ["f1"])
    }

    @Test("Kapitel-Tags gelten nur für die Fassung, die eine Einordnung jetzt lesen würde")
    func chapterTagsFollowTheCurrentVersion() async throws {
        let (store, _) = try await analyzedStore()
        let tag = try #require(try await store.addDetectedTag(label: "Quantencomputer"))
        func chapterTag(media: MediaVersionID, revision: Revision) -> ChapterTag {
            ChapterTag(episodeID: episodeID, mediaVersionID: media, chapterStartMs: 0, chapterEndMs: 20_000,
                       interestID: tag.id, normalizedKey: tag.normalizedKey, confidence: 0.6,
                       matchedKnown: false, sourceID: sourceID, publishedAt: nil, transcriptRevision: revision)
        }

        let written = try await store.commit(
            chapterTags: [chapterTag(media: mediaID, revision: .initial)], media: mediaID,
            transcriptRevision: .initial, under: guardNow())
        #expect(written.receipt?.chapterTagIDs.count == 1)
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 1)

        // Eine andere Fassung ohne Belege: überholt.
        let other = MediaVersionID(stable: "https://example.com/anders.mp3")
        #expect(try await store.commit(
            chapterTags: [chapterTag(media: other, revision: .initial)], media: other,
            transcriptRevision: .initial, under: guardNow()).staleReason == .inputChanged)
        // Eine Revision, die es in den Belegen nicht gibt: überholt.
        #expect(try await store.commit(
            chapterTags: [], media: mediaID, transcriptRevision: Revision(3), under: guardNow()).staleReason
                == .inputChanged)
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 1)
    }

    @Test("Kapitel-Tags aus einer neueren Revision bleiben stehen")
    func newerChapterTagsWin() async throws {
        let (store, _) = try await analyzedStore()
        let tag = try #require(try await store.addDetectedTag(label: "Quantencomputer"))
        let newer = ChapterTag(episodeID: episodeID, mediaVersionID: mediaID, chapterStartMs: 0, chapterEndMs: 20_000,
                               interestID: tag.id, normalizedKey: tag.normalizedKey, confidence: 0.6,
                               matchedKnown: false, sourceID: sourceID, publishedAt: nil, transcriptRevision: Revision(2))
        // So kommt es über iCloud von einem Gerät mit neuerem Transkript.
        try await store.save(chapterTags: [newer], forEpisode: episodeID, transcriptRevision: Revision(2))
        #expect(try await store.commit(chapterTags: [], media: mediaID, transcriptRevision: .initial,
                                       under: guardNow()).staleReason == .superseded)
        #expect(try await store.chapterTags(forEpisode: episodeID).count == 1)
    }

    @Test("Erkannte Tags: geschützt angelegt, nach dem Löschen weg, wenn nichts auf sie zeigt")
    func detectedTagsFollowTheirEpisode() async throws {
        let (store, _) = try await analyzedStore()
        let ledger = RemovalLedger()
        let writeGuard = CommitGuard(episode: episodeID, since: ledger.ticket, ledger: ledger)

        let created = try await store.addDetectedTag(label: "Quantencomputer", under: writeGuard)
        let tag = try #require(created.get().value)
        #expect(created.receipt?.tagIDs == [tag.id])
        // Schon vorhanden: kein neues Tag, nichts im Beleg.
        #expect(try await store.addDetectedTag(label: "Quantencomputer", under: writeGuard).receipt?.tagIDs == [])

        let kept = try #require(try await store.addDetectedTag(label: "Fusionsenergie", under: writeGuard).get().value)
        try await store.setStance(.follow, forTag: kept.id)

        ledger.markRemoved([episodeID])
        #expect(try await store.addDetectedTag(label: "Kernfusion", under: writeGuard).staleReason
                == .removedWhileRunning)
        #expect(try await store.resolveTag("Kernfusion") == nil)

        let removed = try await store.removeOrphanedDetectedTags([tag.id, kept.id])
        #expect(removed == [tag.id])
        #expect(try await store.tags().map(\.id) == [kept.id], "wer folgt, behält das Tag")
    }

    @Test("Ein erkanntes Tag mit Kapitel-Tags einer anderen Folge bleibt")
    func referencedDetectedTagStays() async throws {
        let (store, _) = try await analyzedStore()
        let tag = try #require(try await store.addDetectedTag(label: "Quantencomputer"))
        let elsewhere = EpisodeID(stable: "andere")
        try await store.save(chapterTags: [ChapterTag(
            episodeID: elsewhere, mediaVersionID: MediaVersionID(stable: "m-andere"), chapterStartMs: 0,
            chapterEndMs: 10_000, interestID: tag.id, normalizedKey: tag.normalizedKey, confidence: 0.5,
            matchedKnown: false, sourceID: sourceID, publishedAt: nil, transcriptRevision: .initial)],
            forEpisode: elsewhere, transcriptRevision: .initial)
        #expect(try await store.removeOrphanedDetectedTags([tag.id]).isEmpty)
        #expect(try await store.resolveTag("Quantencomputer")?.id == tag.id)
    }

    @Test("Ein erkanntes Tag, das eine angefangene Einordnung nennt, bleibt")
    func detectedTagInProgressStays() async throws {
        let (store, _) = try await analyzedStore()
        let tag = try #require(try await store.addDetectedTag(label: "Quantencomputer"))
        #expect(try await store.removeOrphanedDetectedTags([tag.id], keeping: [tag.id]).isEmpty)
        #expect(try await store.resolveTag("Quantencomputer")?.id == tag.id)

        var receipt = WriteReceipt(episodeID: episodeID)
        receipt.tagIDs = [tag.id]
        _ = try await store.removeWrites(receipt, keepingTags: [tag.id])
        #expect(try await store.resolveTag("Quantencomputer")?.id == tag.id)
        _ = try await store.removeWrites(receipt)
        #expect(try await store.resolveTag("Quantencomputer") == nil)
    }
}

// MARK: - Späte Schreibvorgänge

@Suite("Wächter im Store: nach dem Beleg aufräumen")
struct ReceiptRemovalTests {

    @Test("Der Beleg räumt nur weg, was dieses Schreiben angelegt hat")
    func removesOnlyWhatWasWritten() async throws {
        let store = try makeStore()
        try await subscribe(store)
        // Über 150 Sekunden: zwei Belege.
        let text = transcript(texts: (0..<20).map { "Satz \($0)" })
        let items = evidence(of: text)
        try #require(items.count == 2)
        // Ein Beleg war schon da, etwa über iCloud.
        try await store.store(evidence: [items[0]])

        let (receipt, _) = try await commit(store, text, ledger: RemovalLedger()).get()
        #expect(receipt.evidenceIDs == items.dropFirst().map(\.id))

        let report = try await store.removeWrites(receipt)
        #expect(report.evidenceIDs == items.dropFirst().map(\.id).sorted { $0.rawValue < $1.rawValue })
        #expect(report.mediaVersionIDs == [mediaID])
        #expect(try await store.evidence(forEpisode: episodeID).map(\.id) == [items[0].id])
        #expect(try await store.transcript(forMedia: mediaID) == nil)
        // Die Zeile der Folge bleibt, ohne Merkzeichen und ohne Fassung.
        #expect(try await store.removedEpisodes().isEmpty)
        #expect(try await store.episodes(ids: [episodeID]).first?.currentMediaVersionID == nil)
    }

    @Test("Fakten und Kapitel-Tags nach dem Beleg, ein leerer Beleg tut nichts")
    func removesFactsAndChapterTags() async throws {
        let store = try makeStore()
        try await subscribe(store)
        let ledger = RemovalLedger()
        let written = try await commit(store, transcript(), ledger: ledger).get().value
        let writeGuard = CommitGuard(episode: episodeID, since: ledger.ticket, ledger: ledger)
        let fact = EpisodeFact(id: "f1", episodeID: episodeID, sourceID: sourceID, evidenceID: written[0].id,
                               mediaVersionID: mediaID, statement: "Aussage", range: range(0, 9_000), modelTier: "test")
        let facts = try #require(try await store.commit(facts: [fact], under: writeGuard).receipt)

        #expect(try await store.removeWrites(WriteReceipt(episodeID: episodeID)) == LibraryStore.RemovalReport())
        #expect(try await store.facts(forEpisode: episodeID).count == 1)

        _ = try await store.removeWrites(facts)
        #expect(try await store.facts(forEpisode: episodeID).isEmpty)
        #expect(try await store.evidence(forEpisode: episodeID).count == written.count, "Belege bleiben")
    }
}

// MARK: - Vermerke für angefangenes Löschen

@Suite("Vermerke für angefangenes Löschen")
struct PendingPurgeTests {

    func makeState() -> DeviceState {
        DeviceState(directory: FileManager.default.temporaryDirectory
            .appending(path: "pendingpurges-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test("Ein Vermerk übersteht einen Neustart und fällt nach der Pflege weg")
    func survivesARestart() async throws {
        let state = makeState()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        let purges = PendingPurges(state: state)
        let purge = PendingPurge(
            scope: .source(sourceID), episodeIDs: [episodeID], storeEpisodeIDs: [],
            mediaVersionIDs: [mediaID], metadataKeys: ["https://example.com/video"],
            detectedTagIDs: [InterestID(rawValue: "tag")])
        #expect(purges.add(purge))
        var report = LibraryStore.RemovalReport()
        report.evidenceIDs = [EvidenceID(rawValue: "e1")]
        report.episodeIDs = [episodeID, EpisodeID(rawValue: "ungeladen")]
        #expect(purges.update(purge.id) { $0.recordStoreRemoval(report) })
        await purges.waitUntilWritten()

        let reopened = PendingPurges(state: DeviceState(directory: state.directory))
        let stored = try #require(reopened.all()?.first)
        #expect(stored.id == purge.id)
        #expect(stored.scope == .source(sourceID))
        #expect(stored.storeDone)
        #expect(stored.episodeIDs == [episodeID, EpisodeID(rawValue: "ungeladen")])
        #expect(stored.evidenceIDs == [EvidenceID(rawValue: "e1")])
        #expect(stored.metadataKeys == ["https://example.com/video"])

        #expect(reopened.remove(purge.id))
        #expect(reopened.all() == [])
        reopened.state.flush()
        #expect(PendingPurges(state: DeviceState(directory: state.directory)).all() == [])
    }

    @Test("Eine Liste, die sich gerade nicht lesen lässt, bleibt unangetastet")
    func unreadableListIsLeftAlone() throws {
        let state = makeState()
        let purges = PendingPurges(state: state)
        purges.add(PendingPurge(scope: .episode, episodeIDs: [episodeID], storeEpisodeIDs: [episodeID]))
        state.flush()
        let file = state.directory.appending(path: PendingPurges.key + ".json")
        let path = file.path(percentEncoded: false)
        let before = try Data(contentsOf: file)
        // Wie vor dem ersten Entsperren: Die Datei liegt da, lesen scheitert.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            try? FileManager.default.removeItem(at: state.directory)
        }

        let locked = PendingPurges(state: DeviceState(directory: state.directory))
        if case .unreadable = locked.state.lookup([PendingPurge].self, for: PendingPurges.key) {} else {
            Issue.record("Die Datei sollte als nicht lesbar gelten")
        }
        #expect(locked.all() == nil)
        #expect(!locked.add(PendingPurge(scope: .elsewhere, episodeIDs: [EpisodeID(rawValue: "x")])))
        #expect(!locked.remove(UUID()))
        locked.state.flush()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try Data(contentsOf: file) == before)
        #expect(PendingPurges(state: DeviceState(directory: state.directory)).all()?.count == 1)
    }

    @Test("Nicht geladene Folgen einer Quelle kommen vor dem Store in den Vermerk")
    func includesUnloadedEpisodes() {
        var purge = PendingPurge(scope: .source(sourceID), episodeIDs: [episodeID], metadataKeys: ["a"])
        let other = EpisodeID(rawValue: "ungeladen")
        purge.include(episodes: [episodeID, other], mediaVersionIDs: [mediaID], metadataKeys: ["a", "b"],
                      detectedTagIDs: [InterestID(rawValue: "t")])
        #expect(purge.episodeIDs == [episodeID, other])
        #expect(purge.mediaVersionIDs == [mediaID])
        #expect(purge.metadataKeys == ["a", "b"])
        #expect(purge.detectedTagIDs == [InterestID(rawValue: "t")])
        #expect(!purge.storeDone)
    }

    @Test("Ein älterer Eintrag ohne neue Felder lässt sich lesen")
    func readsOlderEntries() throws {
        let json = """
            [{"id":"\(UUID().uuidString)","requestedAt":0,"scope":{"episode":{}},"episodeIDs":["e1"]}]
            """
        let decoded = try JSONDecoder().decode([PendingPurge].self, from: Data(json.utf8))
        #expect(decoded.first?.episodeIDs == [EpisodeID(rawValue: "e1")])
        #expect(decoded.first?.storeDone == false)
        #expect(decoded.first?.mediaVersionIDs == [])
    }

    @Test("Ändern unter der Sperre verliert nichts, Warten ohne Blockieren schreibt")
    func updateAndWait() async throws {
        let state = makeState()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        for index in 0..<20 {
            state.update([Int].self, for: "zahlen") { list in list = (list ?? []) + [index] }
        }
        #expect(state.value([Int].self, for: "zahlen") == Array(0..<20))
        await state.waitUntilWritten()
        #expect(DeviceState(directory: state.directory).value([Int].self, for: "zahlen") == Array(0..<20))
        if case .absent = state.lookup([Int].self, for: "gibt-es-nicht") {} else {
            Issue.record("Ein fehlender Wert sollte als nicht da gelten")
        }
    }
}
