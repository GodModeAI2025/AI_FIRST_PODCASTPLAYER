//
//  ResumeAndQueueTests.swift
//  PodcastAIKitTests
//
//  Fortsetzen nach einem Abbruch: Zwischenstand des Transkripts, die
//  gemerkte Warteschlange und die Regel für die Mitteilung „Transkripte
//  pausieren“.
//

import Testing
import Foundation
@testable import PodcastAIKit

private let media = MediaVersionID(rawValue: "fassung-1")

private func range(_ start: Double, _ end: Double) -> MediaTimeRange {
    MediaTimeRange(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
}

private func segment(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: media, range: range(start, end)),
                      range: range(start, end), text: text)
}

@Suite("Transkript fortsetzen")
struct TranscriptResumeTests {

    let assembler = TranscriptAssembler()

    private func checkpoint(through seconds: Double) -> TranscriptCheckpoint {
        TranscriptCheckpoint(
            mediaVersionID: media, locale: "de_DE",
            segments: [segment(0, 10, "Eins."), segment(10, 20, "Zwei."), segment(20, 30, "Drei.")],
            analyzedThrough: MediaTime(seconds: seconds))
    }

    @Test("Der Einstieg liegt vor dem Ende und an einer Segmentgrenze")
    func resumeStartsAtSegmentBoundary() {
        let point = assembler.resumePoint(from: checkpoint(through: 30),
                                          overlap: MediaDuration(seconds: 15))
        // Ende minus Überlappung ist 15 s. Das Segment 10 bis 20 reicht
        // hinein, also beginnt der neue Lauf an seinem Anfang.
        #expect(point.offset == MediaTime(seconds: 10))
        #expect(point.segments.map(\.text) == ["Eins."])
        #expect(point.analyzedThrough == MediaTime(seconds: 30))
    }

    @Test("Überlappung wird ohne doppelte Segmente zusammengeführt")
    func overlapMergesWithoutDuplicates() {
        let point = assembler.resumePoint(from: checkpoint(through: 30),
                                          overlap: MediaDuration(seconds: 15))
        // Der neue Lauf erkennt dieselben Stellen leicht anders wieder und
        // kommt weiter als der alte.
        let incoming: [(range: MediaTimeRange, text: String, isFinal: Bool)] = [
            (range(10.2, 19.9), "Zwei, neu erkannt.", true),
            (range(20, 30.1), "Drei, neu erkannt.", true),
            (range(30.1, 41), "Vier.", true),
        ]
        let merged = assembler.merge(existing: point.segments, incoming: incoming, mediaVersionID: media)

        #expect(merged.map(\.text) == ["Eins.", "Zwei, neu erkannt.", "Drei, neu erkannt.", "Vier."])
        #expect(Set(merged.map(\.id)).count == merged.count)
        for (earlier, later) in zip(merged, merged.dropFirst()) {
            #expect(earlier.range.end <= later.range.start, "Segmente überlappen: \(earlier.range) und \(later.range)")
        }
    }

    @Test("Auch ein Bestand, der in die Überlappung reicht, erzeugt keine Dublette")
    func mergeReplacesOverlappingOldSegment() {
        // Ohne Einstieg an der Segmentgrenze: das alte Segment bleibt im
        // Bestand, und der neue Lauf erkennt es noch einmal.
        let old = [segment(0, 10, "Eins."), segment(10, 20, "Zwei.")]
        let incoming: [(range: MediaTimeRange, text: String, isFinal: Bool)] = [
            (range(10.5, 20), "Zwei, neu.", true),
        ]
        let merged = assembler.merge(existing: old, incoming: incoming, mediaVersionID: media)
        #expect(merged.map(\.text) == ["Eins.", "Zwei, neu."])
    }

    @Test("Nach einem zweiten Abbruch bleibt keine Lücke hinter dem Bestand")
    func secondInterruptionLeavesNoGap() {
        // Der fortgesetzte Lauf kam nur bis 14 s, gemerkt ist aber noch der
        // Stand des ersten Laufs, 30 s.
        let interrupted = TranscriptCheckpoint(
            mediaVersionID: media, locale: "de_DE",
            segments: [segment(0, 10, "Eins."), segment(10, 12, "Zwei."), segment(12, 14, "Drei.")],
            analyzedThrough: MediaTime(seconds: 30))
        let point = assembler.resumePoint(from: interrupted, overlap: MediaDuration(seconds: 15))
        #expect(point.segments.count == 3)
        #expect(point.offset == MediaTime(seconds: 14))
    }

    @Test("Ohne Fortschritt beginnt der Lauf am Anfang")
    func emptyCheckpointStartsAtZero() {
        let empty = TranscriptCheckpoint(mediaVersionID: media, locale: "de_DE", segments: [],
                                         analyzedThrough: .zero)
        let point = assembler.resumePoint(from: empty)
        #expect(point.offset == .zero)
        #expect(point.segments.isEmpty)
    }

    @Test("Zwischenstand übersteht Speichern und Laden, passt nur zu Fassung und Sprache")
    func checkpointRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoints-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranscriptCheckpointStore(directory: directory)
        let saved = checkpoint(through: 30)
        try store.save(saved)

        let loaded = try #require(store.load(mediaVersionID: media, locale: "de_DE"))
        #expect(loaded.segments == saved.segments)
        #expect(loaded.mediaVersionID == media)
        #expect(loaded.analyzedThrough == MediaTime(seconds: 30))
        #expect(loaded.analyzedRangesFlat == [0, 30_000])

        // Andere Sprache: nicht brauchbar, und die Datei geht.
        #expect(store.load(mediaVersionID: media, locale: "en_US") == nil)
        #expect(store.load(mediaVersionID: media, locale: "de_DE") == nil)

        try store.save(saved)
        let later = Date().addingTimeInterval(TranscriptCheckpointStore.maximumAge + 60)
        #expect(store.load(mediaVersionID: media, locale: "de_DE", now: later) == nil)

        try store.save(saved)
        store.remove([media])
        #expect(store.load(mediaVersionID: media, locale: "de_DE") == nil)
    }

    @Test("Beim Start verfallen nur alte Zwischenstände")
    func expiredCheckpointsArePruned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoints-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranscriptCheckpointStore(directory: directory)
        let other = MediaVersionID(rawValue: "fassung-2")
        try store.save(checkpoint(through: 30))
        try store.save(TranscriptCheckpoint(
            mediaVersionID: other, locale: "de_DE", segments: [], analyzedThrough: MediaTime(seconds: 5),
            savedAt: Date().addingTimeInterval(-TranscriptCheckpointStore.maximumAge - 60)))
        try Data("kaputt".utf8).write(to: directory.appendingPathComponent("kaputt.json"))

        store.removeExpired()
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["\(media.rawValue).json"])
    }

    @Test("Ein Zwischenstand über das Ende der Datei hinaus passt nicht")
    func checkpointBeyondFileEndIsDiscarded() {
        let saved = checkpoint(through: 30)
        #expect(ContentPipeline.checkpoint(saved, fits: nil))
        #expect(ContentPipeline.checkpoint(saved, fits: MediaDuration(seconds: 29)))
        #expect(!ContentPipeline.checkpoint(saved, fits: MediaDuration(seconds: 20)))
    }
}

@Suite("Warteschlange merken")
struct AnalysisQueueSnapshotTests {

    private let a = EpisodeID(rawValue: "a")
    private let b = EpisodeID(rawValue: "b")
    private let c = EpisodeID(rawValue: "c")
    private let d = EpisodeID(rawValue: "d")

    @Test("Reihenfolge und Herkunft überstehen Speichern und Laden")
    func roundTrip() throws {
        let snapshot = AnalysisQueueSnapshot(
            running: a, queue: [b, c, d], automatic: [c, d], backlog: [d, b])
        let data = try #require(snapshot.encoded())
        let restored = try #require(AnalysisQueueSnapshot.decoded(from: data))

        #expect(restored == snapshot)
        #expect(restored.entries.map(\.episodeID) == [a, b, c, d])
        #expect(restored.entries.map(\.automatic) == [false, false, true, true])
        // Von Hand Angefordertes gehört nie zum Archiv.
        #expect(restored.entries.map(\.backlog) == [false, false, false, true])
    }

    @Test("Die laufende Folge steht vorn und nur einmal")
    func runningComesFirstOnce() {
        let snapshot = AnalysisQueueSnapshot(running: b, queue: [a, b], automatic: [], backlog: [])
        #expect(snapshot.entries.map(\.episodeID) == [b, a])
    }

    @Test("Wiederhergestellt wird nur, was noch aussteht")
    func restorableFilters() {
        let snapshot = AnalysisQueueSnapshot(running: nil, queue: [a, b, c, d], automatic: [c], backlog: [])
        let kept = snapshot.restorable(known: [a, b, c], finished: [b], automaticAllowed: false)
        #expect(kept.map(\.episodeID) == [a])
        let withAutomatic = snapshot.restorable(known: [a, b, c], finished: [b], automaticAllowed: true)
        #expect(withAutomatic.map(\.episodeID) == [a, c])
    }

    @Test("Kaputte oder fehlende Daten ergeben keine Warteschlange")
    func invalidData() {
        #expect(AnalysisQueueSnapshot.decoded(from: nil) == nil)
        #expect(AnalysisQueueSnapshot.decoded(from: Data("kein json".utf8)) == nil)
    }
}

@Suite("Mitteilung „Transkripte pausieren“")
struct TranscriptPauseNoticeTests {

    private func decide(
        inBackground: Bool = true, pending: Bool = true,
        carrier: TranscriptPauseNotice.Carrier = .none,
        permitted: Bool = true, notified: Bool = false
    ) -> Bool {
        TranscriptPauseNotice.shouldNotify(
            inBackground: inBackground, pendingTranscripts: pending, carrier: carrier,
            permitted: permitted, alreadyNotified: notified)
    }

    @Test("Ohne Träger oder nach Ablauf kommt die Mitteilung")
    func notifiesWithoutCarrier() {
        #expect(decide(carrier: .none))
        #expect(decide(carrier: .expired))
    }

    @Test("Läuft die fortgesetzte Verarbeitung oder ist sie offen, nicht")
    func silentWhileCarried() {
        #expect(!decide(carrier: .carrying))
        #expect(!decide(carrier: .pending))
    }

    @Test("Vorn, ohne Arbeit, ohne Erlaubnis oder schon gesagt: nicht")
    func silentOtherwise() {
        #expect(!decide(inBackground: false))
        #expect(!decide(pending: false))
        #expect(!decide(permitted: false))
        #expect(!decide(notified: true))
    }
}
