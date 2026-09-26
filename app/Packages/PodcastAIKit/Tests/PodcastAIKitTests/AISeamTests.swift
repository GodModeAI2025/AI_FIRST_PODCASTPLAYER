//
//  AISeamTests.swift
//  PodcastAIKitTests
//
//  Die Naht zur KI, ohne Modell: die Tabelle für den Vorrang, der Vorrang
//  auf dem Weg vom Aufrufer bis zur Stelle für Apple Intelligence und der
//  Zustand der Modelle als letzter Wert.
//
//  Eine Stelle, die nur mitschreibt, führt keine Operation aus. Weil die
//  Sitzung erst in der Operation entsteht, erreicht jeder Aufruf die Stelle,
//  auch auf einem Mac ohne Gerätemodell. Bis 0.12 scheiterte er dort schon
//  beim Anlegen der Sitzung, bevor die Stelle ihn sah.
//

import Testing
import Foundation
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIIntelligence
@testable import PodcastAIPersistence

/// Schreibt Art und Vorrang jeder Anfrage mit und führt sie nicht aus.
private final class RecordingScheduler: AIScheduling {
    struct Call: Equatable, Sendable {
        let kind: AIWorkKind
        let priority: AIWorkPriority
    }

    struct NotRun: Error {}

    private let calls = Mutex<[Call]>([])
    var recorded: [Call] { calls.withLock { $0 } }

    func run<T: Sendable>(
        _ kind: AIWorkKind, priority: AIWorkPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        calls.withLock { $0.append(Call(kind: kind, priority: priority)) }
        throw NotRun()
    }
}

/// Merkt sich jeden gemeldeten Stand der Modelle.
private final class StatusLog: Sendable {
    private let values = Mutex<[ModelStatus]>([])
    func add(_ status: ModelStatus) { values.withLock { $0.append(status) } }
    var all: [ModelStatus] { values.withLock { $0 } }
}

/// Ein Schalter, den eine Probe setzt und der Test liest.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// Das Gerätemodell gilt als bereit, Private Cloud Compute nicht.
private let deviceOnly = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))

private func passages(_ texts: [String]) -> [Evidence] {
    texts.enumerated().map { index, text in
        Evidence(
            id: EvidenceID(stable: "naht-\(index)"), mediaVersionID: MediaVersionID(stable: "m"),
            episodeID: EpisodeID(stable: "folge"), sourceID: SourceID(stable: "quelle"),
            transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
            range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 60_000),
                                  end: MediaTime(milliseconds: Int64(index) * 60_000 + 50_000)),
            quotedText: text)
    }
}

private let sample = passages([
    "Der Datenschutz ist bei Anfragen an Sprachmodelle entscheidend.",
    "Die Verordnung verlangt Transparenz von Anbietern.",
])

@Suite("Naht zur KI")
struct AISeamTests {

    // MARK: - Tabelle

    @Test("Die Tabelle: Werte von 0.12, Tags erben die Herkunft, für jede Art, Herkunft und „Jetzt ermitteln“")
    func policyKeepsTodaysValues() {
        for kind in AIWorkKind.allCases {
            for origin in Origin.allCases {
                for force in [false, true] {
                    let expected: AIWorkPriority = switch kind {
                    case .answer, .chapterSummary: .user
                    case .facts: force ? .user : .background
                    // Tags erben die Herkunft des Faktenlaufs (Entscheidung 1),
                    // die Relevanz noch nicht.
                    case .tags: origin == .user ? .user : .background
                    case .relevance, .other: .background
                    }
                    #expect(AIPriorityPolicy.priority(kind: kind, origin: origin, force: force) == expected,
                            "\(kind) \(origin) force: \(force)")
                }
            }
        }
    }

    @Test("Herkunft ordnet sich: Rückstand, von selbst, Mensch")
    func originOrder() {
        #expect(Origin.backlog < .automatic)
        #expect(Origin.automatic < .user)
        #expect(Origin.allCases.max() == .user)
    }

    // MARK: - Vorrang bis zur Stelle

    @Test("Der Extraktor gibt Art und Vorrang an die übergebene Stelle")
    func extractorPassesPriority() async throws {
        let scheduler = RecordingScheduler()
        let extractor = KnowledgeExtractor(scheduler: scheduler)
        let profile = InterestProfile(interests: [Interest(label: "Datenschutz")])

        await #expect(throws: ExtractorError.self) {
            _ = try await extractor.selectRelevant(from: sample, profile: profile, availability: deviceOnly)
        }
        await #expect(throws: ExtractorError.self) {
            _ = try await extractor.selectRelevant(
                from: sample, profile: profile, availability: deviceOnly, priority: .user)
        }
        await #expect(throws: ExtractorError.self) {
            _ = try await extractor.extractClaims(from: sample, availability: deviceOnly)
        }
        await #expect(throws: ExtractorError.self) {
            _ = try await KnowledgeExtractor(priority: .user, scheduler: scheduler)
                .extractClaims(from: sample, availability: deviceOnly)
        }
        await #expect(throws: ExtractorError.self) {
            _ = try await extractor.summarizeChapter(sample, title: "Kapitel", availability: deviceOnly)
        }
        await #expect(throws: ExtractorError.self) {
            _ = try await extractor.answer(question: "Was gilt beim Datenschutz?", from: sample,
                                           availability: deviceOnly)
        }
        #expect(scheduler.recorded == [
            .init(kind: .relevance, priority: .background),
            .init(kind: .relevance, priority: .user),
            .init(kind: .facts, priority: .background),
            .init(kind: .facts, priority: .user),
            .init(kind: .chapterSummary, priority: .user),
            .init(kind: .answer, priority: .user),
        ])
    }

    @Test("Die Auswahl der Tags gibt ihren Vorrang an die übergebene Stelle")
    func tagSelectorPassesPriority() async throws {
        let scheduler = RecordingScheduler()
        let selector = TagSelector(useCase: .general, scheduler: scheduler)
        let choices = [TagChoice(id: "k1", label: "Datenschutz"), TagChoice(id: "n1", label: "Verordnung")]

        await #expect(throws: ExtractorError.self) {
            _ = try await selector.select(from: choices, passages: sample, title: "Kapitel", availability: deviceOnly)
        }
        await #expect(throws: ExtractorError.self) {
            _ = try await selector.select(from: choices, passages: sample, title: "Kapitel",
                                          availability: deviceOnly, priority: .user)
        }
        #expect(scheduler.recorded == [
            .init(kind: .tags, priority: .background),
            .init(kind: .tags, priority: .user),
        ])
    }

    @Test("Die Kapitel eines Themen-Updates fragen das Modell mit dem übergebenen Vorrang")
    func editionChaptersPassPriority() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let source = SourceID(stable: "quelle")
        try await store.upsert(source: Source(id: source, kind: .podcastRSS, title: "Quelle"))
        let audio = URL(string: "https://example.com/naht.mp3")!
        let episode = Episode(id: EpisodeID(stable: "naht"), sourceID: source, title: "Naht", audioURL: audio)
        _ = try await store.upsert(episodes: [episode], forSource: source)
        let media = MediaVersionID(stable: audio.absoluteString)
        let texts = [
            "Heute geht es um Datenschutz in Kliniken.",
            "Der Datenschutz verlangt klare Regeln für Daten.",
            "Zum Schluss noch einmal Datenschutz und Verträge.",
        ]
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(id: SegmentID(stable: "naht-\(index)"),
                              range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 60_000),
                                                    end: MediaTime(milliseconds: Int64(index) * 60_000 + 50_000)),
                              text: text)
        }
        let transcript = Transcript(
            id: TranscriptID(stable: "t-naht"), mediaVersionID: media, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE", segments: segments,
            analyzedRanges: IntervalSet(MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 180_000))))
        try await store.save(transcript: transcript,
                             media: MediaVersion(id: media, episodeID: episode.id, remoteURL: audio),
                             forEpisode: episode.id)
        try await store.store(evidence: segments.map { segment in
            Evidence(id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: segment.range),
                     mediaVersionID: media, episodeID: episode.id, sourceID: source,
                     transcriptID: transcript.id, transcriptRevision: .initial,
                     range: segment.range, quotedText: segment.text)
        })

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAINaht-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let scheduler = RecordingScheduler()
        let pipeline = ContentPipeline(store: store, mediaDirectory: directory, aiScheduler: scheduler)
        let interest = Interest(label: "Datenschutz")
        let profile = InterestProfile(interests: [interest])

        // Ohne Antwort des Modells bleiben die Stichworttreffer.
        let automatic = try await pipeline.editionChapters(
            tags: [interest.id], profile: profile, availability: deviceOnly, titledSections: false)
        _ = try await pipeline.editionChapters(
            tags: [interest.id], profile: profile, availability: deviceOnly, titledSections: false,
            priority: .user)
        #expect(!automatic.isEmpty)
        #expect(scheduler.recorded == [
            .init(kind: .relevance, priority: .background),
            .init(kind: .relevance, priority: .user),
        ])
    }

    // MARK: - Zustand der Modelle

    @Test("Der Monitor liefert den letzten Stand und meldet nur Änderungen")
    func monitorReportsChanges() async throws {
        let ready = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))
        let withCloud = ModelStatus(onDevice: .available, privateCloudCompute: .available)
        let monitor = ModelAvailabilityMonitor(probe: { $0 ? withCloud : ready })
        #expect(monitor.current == ModelAvailabilityMonitor.unchecked)

        let seen = StatusLog()
        let watcher = Task {
            for await status in monitor.updates() { seen.add(status) }
        }
        defer { watcher.cancel() }
        func waitFor(_ count: Int) async throws {
            var tries = 0
            while seen.all.count < count, tries < 200 {
                try await Task.sleep(for: .milliseconds(5))
                tries += 1
            }
        }

        // Wer beginnt zuzuhören, bekommt den Stand jetzt.
        try await waitFor(1)
        #expect(await monitor.refresh(allowPrivateCloud: false) == ready)
        try await waitFor(2)
        #expect(monitor.current == ready)
        // Derselbe Stand noch einmal: keine Meldung.
        await monitor.refresh(allowPrivateCloud: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen.all == [ModelAvailabilityMonitor.unchecked, ready])
        await monitor.refresh(allowPrivateCloud: true)
        try await waitFor(3)
        #expect(seen.all == [ModelAvailabilityMonitor.unchecked, ready, withCloud])
        #expect(monitor.current == withCloud)
    }

    @Test("Eine langsame ältere Antwort überschreibt keinen neueren Stand")
    func monitorIgnoresStaleAnswers() async throws {
        let withCloud = ModelStatus(onDevice: .available, privateCloudCompute: .available)
        let withoutCloud = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))
        // Mit Private Cloud Compute antwortet das System erst, wenn der Test
        // es freigibt. Die Frist hält die Suite nicht an, falls etwas klemmt.
        let started = Flag()
        let release = DispatchSemaphore(value: 0)
        let monitor = ModelAvailabilityMonitor(probe: { allowCloud in
            if allowCloud {
                started.set()
                _ = release.wait(timeout: .now() + 5)
            }
            return allowCloud ? withCloud : withoutCloud
        })
        let slow = Task { await monitor.refresh(allowPrivateCloud: true) }
        // Die langsame Frage hat ihre Nummer, sobald ihre Probe läuft.
        let deadline = ContinuousClock.now + .seconds(5)
        while !started.isSet, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.isSet)
        // Inzwischen abgeschaltet: diese Frage kommt später und antwortet zuerst.
        #expect(await monitor.refresh(allowPrivateCloud: false) == withoutCloud)
        release.signal()
        #expect(await slow.value == withoutCloud)
        #expect(monitor.current == withoutCloud)
    }
}
