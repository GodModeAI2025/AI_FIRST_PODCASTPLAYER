//
//  PipelineFoundationTests.swift
//  PodcastAIKitTests
//
//  Schritt 0 der Stufen-Pipeline (docs/plan-pipeline.md): Ereignisse,
//  Router, Host, Tor und Löschprotokoll. In der App hört noch keine Stufe
//  zu; hier hört ein Rekorder, und der Router wird als Tabelle geprüft.
//

import Testing
import Foundation
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIPersistence

private func episode(_ raw: String) -> EpisodeID { EpisodeID(rawValue: raw) }

/// Je Art ein Ereignis, damit jede Art einmal durch Router und Host geht.
private func sampleEvent(_ kind: PipelineEvent.Kind) -> PipelineEvent {
    let id = episode("e1")
    let media = MediaVersionID(rawValue: "m1")
    let version = InputVersion(mediaVersionID: media, transcriptID: TranscriptID(rawValue: "t1"),
                               revision: .initial, segmentCount: 3, lastEndMs: 9_000)
    return switch kind {
    case .episodesAdded: .episodesAdded([id], .automatic)
    case .audioAvailable: .audioAvailable(id, media)
    case .audioRemoved: .audioRemoved([id])
    case .transcriptSaved: .transcriptSaved(id, version, .user)
    case .transcriptFailed: .transcriptFailed(id, TranscriptFailure(.permanent, message: "kaputt"), .automatic)
    case .evidenceReady: .evidenceReady(id, version, .backlog)
    case .transcriptsIdle: .transcriptsIdle
    case .factsDone: .factsDone(id, version, .stored, .user)
    case .tagsDone: .tagsDone(id, version, .stored, .backlog)
    case .feedsRefreshed: .feedsRefreshed(byUser: true)
    case .editionPublished: .editionPublished(SmartFeedID(rawValue: "f1"), [PersonalEpisodeID(rawValue: "p1")])
    case .episodesRemoved: .episodesRemoved([id], .source(SourceID(rawValue: "s1")))
    case .changedElsewhere: .changedElsewhere(.all)
    }
}

// MARK: - Ereignisse und Router

@Suite("Pipeline: Ereignisse und Router")
struct PipelineRouterTests {

    @Test("Origin ordnet Archiv, von selbst und von Hand")
    func originOrder() {
        #expect(Origin.backlog < .automatic)
        #expect(Origin.automatic < .user)
        #expect([Origin.automatic, .user, .backlog].max() == .user)
        #expect([Origin.automatic, .backlog].max() == .automatic)
    }

    @Test("Jedes Ereignis nennt seine Art")
    func kindsMatch() {
        for kind in PipelineEvent.Kind.allCases {
            #expect(sampleEvent(kind).kind == kind)
        }
    }

    /// Die Verdrahtung als Tabelle, mit den Korrekturen aus der Gegenprüfung:
    /// `feedsRefreshed` auch an Vorbereiten, Wissen, Download und „Für dich“,
    /// „Für dich“ bekommt `evidenceReady` und `episodesRemoved`.
    static let expected: [PipelineEvent.Kind: Set<PipelineStage>] = [
        .episodesAdded: [.prepare, .download],
        .audioAvailable: [.transcript],
        .audioRemoved: [.download, .transcript],
        .transcriptSaved: [.sink],
        .transcriptFailed: [.prepare, .download],
        .evidenceReady: [.prepare, .download, .knowledge, .forYou, .sink],
        .transcriptsIdle: [.editions],
        .factsDone: [.knowledge],
        .tagsDone: [.sink],
        .feedsRefreshed: [.prepare, .download, .knowledge, .forYou, .editions],
        .editionPublished: [.editions],
        .episodesRemoved: [.prepare, .download, .transcript, .knowledge, .editions, .maintenance, .forYou, .sink],
        .changedElsewhere: [.prepare, .download, .transcript, .knowledge, .editions, .maintenance, .forYou],
    ]

    @Test("Der Router folgt der Tabelle, für jede Art", arguments: PipelineEvent.Kind.allCases)
    func routingTable(kind: PipelineEvent.Kind) throws {
        let expected = try #require(Self.expected[kind])
        let receivers = PipelineRouter.receivers(of: kind)
        #expect(Set(receivers) == expected)
        // Kein Empfänger doppelt.
        #expect(receivers.count == expected.count)
        let event = sampleEvent(kind)
        let deliveries = PipelineRouter.deliveries(for: event)
        #expect(deliveries.map(\.stage) == receivers)
        #expect(deliveries.allSatisfy { $0.event == event })
    }

    @Test("Folge löschen erreicht jede Stufe mit Arbeit (Regel 5)")
    func removalReachesEveryStage() {
        let receivers = Set(PipelineRouter.receivers(of: .episodesRemoved))
        for stage in [PipelineStage.prepare, .download, .transcript, .knowledge, .editions, .maintenance, .forYou] {
            #expect(receivers.contains(stage), "\(stage) erfährt nichts vom Löschen")
        }
    }

    @Test("Audio entfernen erreicht weder Wissen noch Pflege (Regel 5)")
    func audioRemovalKeepsData() {
        let receivers = Set(PipelineRouter.receivers(of: .audioRemoved))
        #expect(!receivers.contains(.knowledge))
        #expect(!receivers.contains(.maintenance))
        #expect(!receivers.contains(.sink))
    }
}

// MARK: - Host

@Suite("Pipeline: Host und Postfächer")
struct PipelineHostTests {

    /// Holt die nächsten `count` Ereignisse aus einem Postfach. Sie liegen
    /// schon im Puffer, also wartet das nicht.
    func take(_ count: Int, from stream: AsyncStream<PipelineEvent>) async -> [PipelineEvent] {
        var iterator = stream.makeAsyncIterator()
        var events: [PipelineEvent] = []
        for _ in 0..<count {
            guard let event = await iterator.next() else { break }
            events.append(event)
        }
        return events
    }

    @Test("Ohne Zuhörer fällt ein Ereignis weg")
    func dropsWithoutListener() async {
        let host = PipelineHost()
        #expect(host.listeningStages.isEmpty)
        for kind in PipelineEvent.Kind.allCases {
            #expect(!host.hasListeners(for: kind))
            host.emit(sampleEvent(kind))
        }
        // Wer danach zuhört, bekommt nur, was danach kommt.
        let mailbox = host.mailbox(for: .knowledge)
        #expect(host.hasListeners(for: .factsDone))
        #expect(!host.hasListeners(for: .transcriptsIdle))
        host.emit(.transcriptsIdle)
        host.emit(sampleEvent(.factsDone))
        #expect(await take(1, from: mailbox) == [sampleEvent(.factsDone)])
    }

    @Test("Ein Rekorder an allen Stufen bekommt jedes Ereignis in der Reihenfolge des Sendens")
    func recorderSeesEverythingInOrder() async {
        let host = PipelineHost()
        var mailboxes: [PipelineStage: AsyncStream<PipelineEvent>] = [:]
        for stage in PipelineStage.allCases { mailboxes[stage] = host.mailbox(for: stage) }
        #expect(host.listeningStages == Set(PipelineStage.allCases))

        let sent = PipelineEvent.Kind.allCases.map(sampleEvent)
        for event in sent { host.emit(event) }

        for stage in PipelineStage.allCases {
            let wanted = sent.filter { PipelineRouter.receivers(of: $0.kind).contains(stage) }
            let got = await take(wanted.count, from: mailboxes[stage]!)
            #expect(got == wanted, "\(stage)")
        }
    }

    @Test("Eine Stufe hat einen Besitzer: ein zweites Postfach beendet das erste")
    func secondMailboxReplacesFirst() async {
        let host = PipelineHost()
        let first = host.mailbox(for: .download)
        let second = host.mailbox(for: .download)
        host.emit(.audioRemoved([episode("a")]))
        var old = first.makeAsyncIterator()
        #expect(await old.next() == nil)
        #expect(await take(1, from: second) == [.audioRemoved([episode("a")])])
        #expect(host.listeningStages == [.download])
    }

    @Test("Was nach einem await gesendet wird, kommt nie hinter dem Löschen der Folge an")
    func delayedEventsRespectRemoval() async {
        let host = PipelineHost()
        let ledger = RemovalLedger()
        let mailbox = host.mailbox(for: .knowledge)
        let id = episode("e1")
        let ready = sampleEvent(.evidenceReady)
        let facts = sampleEvent(.factsDone)
        let removed = PipelineEvent.episodesRemoved([id], .episode)

        let ticket = ledger.ticket
        #expect(host.emit([ready], about: id, unlessRemovedSince: ticket, in: ledger))
        // Gelöscht wie in der App: erst ins Protokoll, dann das Ereignis.
        ledger.markRemoved([id])
        host.emit(removed)
        // Das Ergebnis eines Laufs, der vor dem Löschen begann, fällt weg.
        #expect(!host.emit([facts], about: id, unlessRemovedSince: ticket, in: ledger))
        // Eine andere Folge ist nicht betroffen.
        let other = PipelineEvent.factsDone(
            episode("e2"), InputVersion(mediaVersionID: MediaVersionID(rawValue: "m2"),
                                        transcriptID: TranscriptID(rawValue: "t2"), revision: .initial,
                                        segmentCount: 1, lastEndMs: 1_000),
            .stored, .automatic)
        #expect(host.emit([other], about: episode("e2"), unlessRemovedSince: ticket, in: ledger))
        // Neu abonniert: Arbeit nach dem Löschen meldet sich wieder.
        #expect(host.emit([facts], about: id, unlessRemovedSince: ledger.ticket, in: ledger))

        #expect(await take(4, from: mailbox) == [ready, removed, other, facts])
    }

    @Test("Hört der Leser auf, fällt das Postfach weg")
    func mailboxEndsWithReader() async {
        let host = PipelineHost()
        let mailbox = host.mailbox(for: .editions)
        let reader = Task { for await _ in mailbox {} }
        reader.cancel()
        await reader.value
        #expect(!host.listeningStages.contains(.editions))
        #expect(!host.hasListeners(for: .transcriptsIdle))
    }
}

// MARK: - Löschprotokoll

@Suite("Pipeline: Löschprotokoll")
struct RemovalLedgerTests {

    @Test("Eine Arbeit sieht nur Löschungen nach ihrem Start")
    func ticketsCountFromStart() {
        let ledger = RemovalLedger()
        let before = ledger.ticket
        #expect(!ledger.wasRemoved(episode("a"), since: before))
        #expect(!ledger.hasRemovals(since: before))
        ledger.markRemoved([episode("a")])
        #expect(ledger.wasRemoved(episode("a"), since: before))
        #expect(!ledger.wasRemoved(episode("b"), since: before))
        #expect(ledger.hasRemovals(since: before))
        // Eine Arbeit, die erst nach der Löschung beginnt, ist nicht betroffen.
        #expect(!ledger.wasRemoved(episode("a"), since: ledger.ticket))
    }

    @Test("Neu abonniert im selben Prozess: dieselbe Kennung gilt wieder")
    func resubscribeKeepsNewWork() {
        let ledger = RemovalLedger()
        let old = ledger.ticket
        ledger.markRemoved([episode("a")], source: SourceID(rawValue: "s"))
        let fresh = ledger.ticket
        #expect(ledger.wasRemoved(episode("a"), since: old))
        #expect(!ledger.wasRemoved(episode("a"), since: fresh))
        #expect(ledger.wasRemoved(source: SourceID(rawValue: "s"), since: old))
        #expect(!ledger.wasRemoved(source: SourceID(rawValue: "s"), since: fresh))
        // Eine zweite Löschung trifft auch die neue Arbeit.
        ledger.markRemoved([episode("a")])
        #expect(ledger.wasRemoved(episode("a"), since: fresh))
    }

    @Test("Eine Abbestellung ohne geladene Folgen zählt als neuer Stand")
    func emptySourceRemovalCounts() {
        let ledger = RemovalLedger()
        let before = ledger.ticket
        ledger.markRemoved([], source: SourceID(rawValue: "s"))
        #expect(ledger.hasRemovals(since: before))
        #expect(ledger.wasRemoved(source: SourceID(rawValue: "s"), since: before))
        #expect(!ledger.wasRemoved(source: SourceID(rawValue: "t"), since: before))
    }

    @Test("Nach der Löschung läuft nichts mehr unter der Sperre")
    func unlessRemovedRefusesLateWork() {
        let ledger = RemovalLedger()
        let ticket = ledger.ticket
        #expect(ledger.unlessRemoved(episode("a"), since: ticket) { 1 } == 1)
        ledger.markRemoved([episode("a")])
        var ran = false
        #expect(ledger.unlessRemoved(episode("a"), since: ticket) { ran = true } == nil)
        #expect(!ran)
    }

    @Test("Eine Datei einer gelöschten Folge kommt nicht zurück, auch kein Ordner")
    func fileWriteRespectsRemoval() throws {
        let ledger = RemovalLedger()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemovalLedgerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a", isDirectory: true).appendingPathComponent("x.json")
        let data = Data("{}".utf8)

        let ticket = ledger.ticket
        #expect(ledger.write(data, to: file, staging: root, for: episode("a"), since: ticket))
        #expect(try Data(contentsOf: file) == data)
        // Die Zwischendatei lag nicht im Ordner des Zwischenspeichers.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["a"])
        // Überschreiben geht auch.
        #expect(ledger.write(Data("[]".utf8), to: file, staging: root, for: episode("a"), since: ticket))
        #expect(try Data(contentsOf: file) == Data("[]".utf8))

        // Gelöscht: erst ins Protokoll, dann die Dateien weg.
        ledger.markRemoved([episode("a")])
        try FileManager.default.removeItem(at: root.appendingPathComponent("a", isDirectory: true))
        #expect(!ledger.write(data, to: file, staging: root, for: episode("a"), since: ticket))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        // Keine Zwischendatei bleibt liegen.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        // Eine Arbeit nach der Löschung darf wieder schreiben.
        #expect(ledger.write(data, to: file, staging: root, for: episode("a"), since: ledger.ticket))
    }
}

// MARK: - Tor

@Suite("Pipeline: Tor")
struct WorkGateTests {

    /// Alle Zustände: vorn oder nicht, pausiert, beim Leeren, und jede
    /// Menge von Trägern.
    static var allConditions: [WorkConditions] {
        var result: [WorkConditions] = []
        let carriers = WorkCarrier.allCases
        for mask in 0..<(1 << carriers.count) {
            let held = Dictionary(uniqueKeysWithValues: carriers.enumerated()
                .filter { mask & (1 << $0.offset) != 0 }.map { ($0.element, 1) })
            for foreground in [false, true] {
                for paused in [false, true] {
                    for cancelling in [false, true] {
                        result.append(WorkConditions(inForeground: foreground, paused: paused,
                                                     cancelling: cancelling, carriers: held))
                    }
                }
            }
        }
        return result
    }

    @Test("Das Tor rechnet genau wie mayStart, factsMayRun und tagsMayRun")
    func matchesTodaysRules() {
        for conditions in Self.allConditions {
            // Wie im AppModel: `queueHeld`, `factsGrants` (Worker der
            // Transkripte und `com.podcastai.analysis`), `tagGrants`.
            let queueHeld = conditions.paused || conditions.cancelling
            let factsGrants = conditions.holds(.continued) || conditions.holds(.analysisTask)
            let tagGrants = conditions.holds(.taggingTask)
            let mayStart = AnalysisQueueControl.mayStart(
                paused: conditions.paused, inForeground: conditions.inForeground,
                cancelling: conditions.cancelling)
            let factsMayRun = !queueHeld && (conditions.inForeground || factsGrants)
            let tagsMayRun = factsMayRun || (tagGrants && !queueHeld)
            for origin in Origin.allCases {
                #expect(conditions.mayRun(.transcript, origin: origin) == mayStart, "\(conditions)")
                #expect(conditions.mayRun(.facts, origin: origin) == factsMayRun, "\(conditions)")
                #expect(conditions.mayRun(.tags, origin: origin) == tagsMayRun, "\(conditions)")
            }
        }
    }

    @Test("UIKit und Siri geben heute weder Fakten noch Tags Zeit")
    func uikitAndSiriGrantNothingYet() {
        let conditions = WorkConditions(inForeground: false, carriers: [.uikit: 1, .siri: 1])
        #expect(!conditions.mayRun(.facts, origin: .user))
        #expect(!conditions.mayRun(.tags, origin: .user))
        #expect(!conditions.mayRun(.transcript, origin: .user))
    }

    @Test("Auf dem Mac gilt die App immer als vorn")
    func macIsAlwaysInForeground() {
        let gate = WorkGate(alwaysInForeground: true, inForeground: false)
        #expect(gate.current.inForeground)
        gate.setInForeground(false)
        #expect(gate.mayRun(.transcript, origin: .automatic))
        gate.setPaused(true)
        #expect(!gate.mayRun(.facts, origin: .user))
    }

    @Test("Eine Leihe endet genau einmal, auch ohne release")
    func leaseReleasesOnce() {
        let gate = WorkGate(alwaysInForeground: false, inForeground: false)
        let first = gate.hold(.analysisTask)
        let second = gate.hold(.analysisTask)
        #expect(gate.current.carriers[.analysisTask] == 2)
        #expect(gate.mayRun(.facts, origin: .automatic))
        first.release()
        first.release()
        #expect(first.isReleased)
        #expect(gate.current.carriers[.analysisTask] == 1)
        second.release()
        #expect(gate.current.carriers[.analysisTask] == nil)
        #expect(!gate.mayRun(.facts, origin: .automatic))
        do {
            _ = gate.hold(.taggingTask)
        }
        #expect(!gate.current.holds(.taggingTask))
    }

    @Test("Wer zuhört, bekommt den Stand jetzt und danach nur Änderungen")
    func updatesDeliverLatestState() async {
        let gate = WorkGate(alwaysInForeground: false, inForeground: true)
        var updates = gate.updates().makeAsyncIterator()
        #expect(await updates.next()?.inForeground == true)
        gate.setPaused(false)          // keine Änderung, keine Meldung
        gate.setPaused(true)
        #expect(await updates.next()?.paused == true)
        // Wer langsam liest, bekommt nur den neuesten Stand.
        gate.setInForeground(false)
        gate.setCancelling(true)
        let latest = await updates.next()
        #expect(latest?.inForeground == false)
        #expect(latest?.cancelling == true)
    }
}

// MARK: - Store

@Suite("Pipeline: Kennungen neuer Folgen und Eingangsfassung")
struct PipelineStoreTests {

    let sourceID = SourceID(stable: "quelle-pipeline")
    let audio = URL(string: "https://example.com/pipeline.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }

    func emptyStore() async throws -> LibraryStore {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        return store
    }

    func make(_ key: String) -> Episode {
        Episode(id: EpisodeID(stable: "pipeline-\(key)"), sourceID: sourceID, title: key, audioURL: audio)
    }

    @Test("upsertEpisodes nennt nur die neu angelegten Folgen")
    func upsertReturnsNewIDs() async throws {
        let store = try await emptyStore()
        let first = [make("a"), make("b")]
        #expect(try await store.upsertEpisodes(first, forSource: sourceID) == first.map(\.id))
        let second = [make("b"), make("c")]
        #expect(try await store.upsertEpisodes(second, forSource: sourceID) == [make("c").id])
        #expect(try await store.upsert(episodes: second, forSource: sourceID) == 0)

        // Gelöscht bleibt gelöscht und zählt nicht als neu.
        _ = try await store.removeEpisode(make("a").id)
        #expect(try await store.upsertEpisodes([make("a")], forSource: sourceID).isEmpty)
        // Ohne Quelle entsteht nichts.
        #expect(try await store.upsertEpisodes([make("d")], forSource: SourceID(rawValue: "fehlt")).isEmpty)
    }

    @Test("Die Eingangsfassung kommt aus dem gespeicherten Transkript der Fassung")
    func fingerprintForMedia() async throws {
        let store = try await emptyStore()
        let item = make("t")
        _ = try await store.upsertEpisodes([item], forSource: sourceID)
        #expect(try await store.transcriptFingerprint(forMedia: mediaID) == nil)

        let range = { (start: Int64, end: Int64) in
            MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
        }
        let segments = [(0, 4_000, "Hallo"), (4_000, 9_500, "Welt")].map { start, end, text in
            TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: mediaID, range: range(start, end)),
                              range: range(start, end), text: text)
        }
        let transcript = Transcript(
            id: TranscriptID(stable: "\(mediaID.rawValue)|de_DE"), mediaVersionID: mediaID,
            revision: .initial, origin: .speechAnalysis, locale: "de_DE", segments: segments,
            analyzedRanges: IntervalSet(segments.map(\.range)), createdAt: Date())
        try await store.save(transcript: transcript,
                             media: MediaVersion(id: mediaID, episodeID: item.id, remoteURL: audio),
                             forEpisode: item.id)

        let print = try #require(try await store.transcriptFingerprint(forMedia: mediaID))
        #expect(print == LibraryStore.TranscriptFingerprint(transcript))
        #expect(try await store.transcriptFingerprint(forEpisode: item.id) == print)
        #expect(try await store.transcriptFingerprint(forMedia: MediaVersionID(rawValue: "andere")) == nil)

        let version = InputVersion(mediaVersionID: mediaID, fingerprint: print)
        #expect(version.fingerprint == print)
        #expect(version.segmentCount == 2)
        #expect(version.lastEndMs == 9_500)
    }
}
