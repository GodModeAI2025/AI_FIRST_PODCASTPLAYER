//
//  WidgetSnapshotTests.swift
//  PodcastAIKitTests
//
//  Der Schnappschuss fürs Widget „Was ist neu“: was in der Datei steht,
//  wie er zusammengestellt wird, wann er geschrieben wird und welche
//  Adressen die App öffnet.
//

import Foundation
import Synchronization
import Testing
import PodcastAIWidgetData

// MARK: - Hilfen

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

private func tag(_ id: String, _ label: String, _ count: Int) -> WidgetSnapshot.TagCount {
    WidgetSnapshot.TagCount(tagID: id, label: label, count: count)
}

private func edition(_ id: String, at offset: TimeInterval) -> WidgetSnapshot.Edition {
    WidgetSnapshot.Edition(id: id, title: "Datenschutz, Teil 1", feedTitle: "Datenschutz",
                           publishedAt: start.addingTimeInterval(offset))
}

private func snapshot(
    _ tags: [WidgetSnapshot.TagCount], edition: WidgetSnapshot.Edition? = nil,
    trending: [WidgetSnapshot.TagCount] = [], at offset: TimeInterval = 0
) -> WidgetSnapshot {
    WidgetSnapshot(generatedAt: start.addingTimeInterval(offset), newStatements: tags,
                   latestEdition: edition, trendingTags: trending)
}

private func temporaryStore() -> WidgetSnapshotStore {
    WidgetSnapshotStore(directory: FileManager.default.temporaryDirectory
        .appending(path: "widget-\(UUID().uuidString)", directoryHint: .isDirectory))
}

private func removeStore(_ store: WidgetSnapshotStore) {
    try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent().deletingLastPathComponent())
}

/// Eine Uhr, die nur weitergeht, wenn der Test es sagt.
private final class ManualClock: Sendable {
    private let current = Mutex(start)
    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Was in der Datei stand, als der Rückruf kam.
private final class SeenFiles: Sendable {
    private let entries = Mutex<[WidgetSnapshot?]>([])
    var files: [WidgetSnapshot?] { entries.withLock { $0 } }
    func note(_ file: WidgetSnapshot?) { entries.withLock { $0.append(file) } }
}

/// Ein Warten, das endet, wenn der Test es sagt.
private actor ManualSleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [CheckedContinuation<Void, any Error>] = []

    var sleeping: Int { waiting.count }

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func wake() {
        let woken = waiting
        waiting = []
        for continuation in woken { continuation.resume() }
    }
}

/// Wartet, bis die Bedingung gilt, höchstens zwei Sekunden.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func makeWriter(
    _ store: WidgetSnapshotStore, clock: ManualClock, sleeper: ManualSleeper
) -> WidgetSnapshotWriter {
    WidgetSnapshotWriter(
        store: store, throttle: WidgetSnapshotThrottle(minimumInterval: 300),
        now: { clock.now }, sleep: { try await sleeper.sleep($0) })
}

// MARK: - Datei

@Suite struct WidgetSnapshotEncodingTests {

    /// Nur Zahlen, Titel und Kennungen. Ein neues Feld fällt hier auf,
    /// bevor es Text aus einem Transkript ins Widget trägt.
    @Test func containsOnlyCountsAndTitles() throws {
        let value = snapshot([tag("t1", "Datenschutz", 4)], edition: edition("e1", at: 0),
                             trending: [tag("t2", "KI-Verordnung", 7)])
        let data = try WidgetSnapshotStore.encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "generatedAt", "newStatements", "latestEdition", "trendingTags"])
        let tags = try #require(object["newStatements"] as? [[String: Any]])
        #expect(tags.map { Set($0.keys) } == [["tagID", "label", "count"]])
        let trending = try #require(object["trendingTags"] as? [[String: Any]])
        #expect(trending.map { Set($0.keys) } == [["tagID", "label", "count"]])
        let latest = try #require(object["latestEdition"] as? [String: Any])
        #expect(Set(latest.keys) == ["id", "title", "feedTitle", "publishedAt"])
    }

    /// Datum mit Bruchteilen kommt genau so zurück, sonst hielte der
    /// Vergleich mit der Datei dieselbe Ausgabe für eine andere.
    @Test func roundTripsThroughTheFile() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let value = snapshot([tag("t1", "Datenschutz", 4), tag("t2", "Energie", 2)],
                             edition: edition("e1", at: 0.125))
        try store.write(value)
        #expect(store.read() == value)
    }

    /// Eine Datei ohne Trends und ohne Ausgabe, etwa aus einer älteren
    /// Fassung der App, liest sich mit leeren Feldern.
    @Test func readsAFileWithoutTrends() throws {
        let json = #"{"format":1,"generatedAt":10,"newStatements":[{"tagID":"t1","label":"Datenschutz","count":3}]}"#
        let value = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(value.trendingTags.isEmpty)
        #expect(value.latestEdition == nil)
        #expect(value.newStatements == [tag("t1", "Datenschutz", 3)])
    }

    @Test func aMissingOrBrokenFileReadsAsNothing() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        #expect(store.read() == nil)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }
}

// MARK: - Zusammenstellen und Vergleichen

@Suite struct WidgetSnapshotContentTests {

    @Test func keepsTheThreeFollowedTagsWithTheMostNewStatements() {
        let value = WidgetSnapshot.whatsNew(
            newStatements: [tag("a", "Automatisierung", 2), tag("b", "Batterie", 9), tag("c", "Cloud", 5),
                            tag("d", "Datenschutz", 5), tag("e", "Energie", 0), tag("f", "Fremd", 20)],
            followedTagIDs: ["a", "b", "c", "d", "e"],
            editions: [edition("alt", at: 0), edition("neu", at: 60), edition("mitte", at: 30)],
            generatedAt: start)
        // Nicht gefolgt und ohne neue Aussage fällt weg, Gleichstand nach dem Namen.
        #expect(value.newStatements.map(\.tagID) == ["b", "c", "d"])
        #expect(value.latestEdition?.id == "neu")
        #expect(value.trendingTags.isEmpty)
    }

    @Test func withoutAnythingTheSnapshotIsEmpty() {
        let value = WidgetSnapshot.whatsNew(newStatements: [], followedTagIDs: [], editions: [])
        #expect(value.isEmpty)
    }

    @Test func sameContentIgnoresWhenItWasMade() {
        let first = snapshot([tag("t1", "Datenschutz", 4)], at: 0)
        let later = snapshot([tag("t1", "Datenschutz", 4)], at: 600)
        #expect(later.hasSameContent(as: first))
        #expect(!snapshot([tag("t1", "Datenschutz", 5)]).hasSameContent(as: first))
    }

    @Test func growingWithdrawsNothing() {
        let old = snapshot([tag("t1", "Datenschutz", 4)], edition: edition("e1", at: 0))
        let grown = snapshot([tag("t1", "Datenschutz", 6), tag("t2", "Energie", 1)], edition: edition("e2", at: 60))
        #expect(!grown.withdraws(from: old))
        #expect(!old.withdraws(from: WidgetSnapshot(generatedAt: start)))
    }

    /// „Folge löschen“, „Abbestellen“, ein gelöschtes Update.
    @Test func shrinkingOrRemovingWithdraws() {
        let old = snapshot([tag("t1", "Datenschutz", 4), tag("t2", "Energie", 2)], edition: edition("e2", at: 60))
        // Die Ausgabe ist weg.
        #expect(snapshot(old.newStatements).withdraws(from: old))
        // Eine ältere Ausgabe ist jetzt die neueste.
        #expect(snapshot(old.newStatements, edition: edition("e1", at: 0)).withdraws(from: old))
        // Eine Zahl ist kleiner.
        #expect(snapshot([tag("t1", "Datenschutz", 3), tag("t2", "Energie", 2)], edition: edition("e2", at: 60))
            .withdraws(from: old))
        // Ein Tag fehlt.
        #expect(snapshot([tag("t1", "Datenschutz", 4)], edition: edition("e2", at: 60)).withdraws(from: old))
        // Ein angesagtes Tag fehlt.
        let trending = snapshot(old.newStatements, edition: old.latestEdition, trending: [tag("t3", "KI", 5)])
        #expect(old.withdraws(from: trending))
    }
}

// MARK: - Wann geschrieben wird

@Suite struct WidgetSnapshotThrottleTests {

    private let throttle = WidgetSnapshotThrottle(minimumInterval: 300)
    private let written = snapshot([tag("t1", "Datenschutz", 4)])

    @Test func withoutAFileItWritesAtOnce() {
        #expect(throttle.decide(written, lastWritten: nil, lastWriteAt: nil, now: start) == .now)
    }

    @Test func theSameContentIsNotWrittenAgain() {
        let again = snapshot([tag("t1", "Datenschutz", 4)], at: 900)
        #expect(throttle.decide(again, lastWritten: written, lastWriteAt: start, now: start) == .unchanged)
        #expect(throttle.decide(again, lastWritten: written, lastWriteAt: nil, now: start) == .unchanged)
    }

    @Test func growthWaitsForTheInterval() {
        let grown = snapshot([tag("t1", "Datenschutz", 6)])
        #expect(throttle.decide(grown, lastWritten: written, lastWriteAt: start, now: start.addingTimeInterval(60))
            == .later(start.addingTimeInterval(300)))
        #expect(throttle.decide(grown, lastWritten: written, lastWriteAt: start, now: start.addingTimeInterval(300))
            == .now)
        // Der erste Stand nach dem Start, wenn die Datei älter ist.
        #expect(throttle.decide(grown, lastWritten: written, lastWriteAt: nil, now: start) == .now)
    }

    @Test func withdrawingWritesAtOnce() {
        let shrunk = snapshot([tag("t1", "Datenschutz", 1)])
        #expect(throttle.decide(shrunk, lastWritten: written, lastWriteAt: start, now: start.addingTimeInterval(1))
            == .now)
    }
}

@Suite struct WidgetSnapshotWriterTests {

    @Test func writesTheFirstStateAtOnce() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        let first = snapshot([tag("t1", "Datenschutz", 4)])
        await writer.submit(first)
        #expect(await writer.writeCount == 1)
        #expect(store.read() == first)
    }

    /// Drei Stände in fünf Minuten: einmal geschrieben, der letzte.
    @Test func coalescesGrowthIntoOneWriteWithTheLatestState() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)]))

        clock.advance(by: 60)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 5)]))
        #expect(await eventually { await sleeper.sleeping == 1 })
        #expect(await sleeper.requested == [.seconds(240)])

        clock.advance(by: 60)
        let latest = snapshot([tag("t1", "Datenschutz", 7), tag("t2", "Energie", 1)], edition: edition("e1", at: 120))
        await writer.submit(latest)
        // Kein zweites Warten, der wartende Stand wird ersetzt.
        #expect(await sleeper.requested.count == 1)
        #expect(await writer.writeCount == 1)

        clock.advance(by: 180)
        await sleeper.wake()
        #expect(await eventually { await writer.writeCount == 2 })
        #expect(store.read() == latest)
    }

    @Test func theSameContentIsNotWrittenAgain() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)]))
        clock.advance(by: 900)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)], at: 900))
        #expect(await writer.writeCount == 1)
        #expect(await sleeper.requested.isEmpty)
    }

    /// Nach „Folge löschen“ zeigt das Widget sofort den neuen Stand, und
    /// der wartende ältere Stand kommt nicht mehr.
    @Test func aWithdrawalWritesAtOnceAndDropsTheWaitingState() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)], edition: edition("e1", at: 0)))

        clock.advance(by: 30)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 6)], edition: edition("e1", at: 0)))
        #expect(await eventually { await sleeper.sleeping == 1 })

        clock.advance(by: 10)
        let afterDeletion = snapshot([tag("t1", "Datenschutz", 2)])
        await writer.submit(afterDeletion)
        #expect(await writer.writeCount == 2)
        #expect(store.read() == afterDeletion)

        // Das abgebrochene Warten wacht auf und schreibt nichts.
        clock.advance(by: 600)
        await sleeper.wake()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await writer.writeCount == 2)
        #expect(store.read() == afterDeletion)
    }

    /// Kommt der Stand der Datei zurück, während ein anderer wartet, bleibt
    /// die Datei, wie sie ist.
    @Test func returningToTheWrittenStateDropsTheWaitingState() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        let written = snapshot([tag("t1", "Datenschutz", 4)])
        await writer.submit(written)
        clock.advance(by: 30)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 6)]))
        clock.advance(by: 30)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)], at: 60))
        #expect(await eventually { await sleeper.sleeping == 1 })
        clock.advance(by: 600)
        await sleeper.wake()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await writer.writeCount == 1)
        #expect(store.read() == written)
    }

    @Test func flushWritesTheWaitingStateWithoutWaiting() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)]))
        clock.advance(by: 10)
        let waiting = snapshot([tag("t1", "Datenschutz", 8)])
        await writer.submit(waiting)
        await writer.flush()
        #expect(await writer.writeCount == 2)
        #expect(store.read() == waiting)
        await sleeper.wake()
    }

    /// Nach einem Neustart zählt die Datei als geschrieben: derselbe Inhalt
    /// schreibt nichts, ein anderer sofort.
    @Test func aRestartComparesWithTheFile() async throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        try store.write(snapshot([tag("t1", "Datenschutz", 4)]))
        let clock = ManualClock(), sleeper = ManualSleeper()
        let writer = makeWriter(store, clock: clock, sleeper: sleeper)
        await writer.submit(snapshot([tag("t1", "Datenschutz", 4)], at: 60))
        #expect(await writer.writeCount == 0)
        let grown = snapshot([tag("t1", "Datenschutz", 5)])
        await writer.submit(grown)
        #expect(await writer.writeCount == 1)
        #expect(store.read() == grown)
    }

    @Test func callsBackAfterTheFileIsWritten() async {
        let store = temporaryStore()
        defer { removeStore(store) }
        let seen = SeenFiles()
        let writer = WidgetSnapshotWriter(store: store, didWrite: { seen.note(store.read()) })
        let value = snapshot([tag("t1", "Datenschutz", 4)])
        await writer.submit(value)
        #expect(seen.files == [value])
    }
}

// MARK: - Adressen

@Suite struct WidgetLinkTests {

    @Test func buildsAndReadsItsOwnAddresses() throws {
        #expect(WidgetLink.topicUpdates.url.absoluteString == "podcastai://topicupdates")
        let id = "6F1C2B0E-1D3A-4C5B-9E8F-0A1B2C3D4E5F"
        #expect(WidgetLink.tag(id).url.absoluteString == "podcastai://tag/\(id)")
        #expect(WidgetLink(url: WidgetLink.topicUpdates.url) == .topicUpdates)
        #expect(WidgetLink(url: WidgetLink.tag(id).url) == .tag(id))
        #expect(WidgetLink(url: try #require(URL(string: "PODCASTAI://TopicUpdates"))) == .topicUpdates)
    }

    /// Andere Apps können jede Adresse öffnen. Was nicht von uns stammt,
    /// führt nirgendwohin.
    @Test(arguments: [
        "https://topicupdates", "podcastai://play/123", "podcastai://topicupdates/mehr",
        "podcastai://tag", "podcastai://tag/", "podcastai://tag/a/b", "podcastai://tag/%3Cscript%3E",
        "podcastai://tag/" + String(repeating: "a", count: 129),
    ])
    func ignoresForeignAddresses(_ address: String) throws {
        #expect(WidgetLink(url: try #require(URL(string: address))) == nil)
    }
}
