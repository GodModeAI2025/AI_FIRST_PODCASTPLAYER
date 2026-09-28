//
//  BackgroundRunProgressTests.swift
//  PodcastAIKitTests
//
//  Der Fortschritt eines Laufs im Hintergrund: wächst nur, über Folgen
//  hinweg, und bleibt auch in langen Schritten ohne Meldung nicht stehen.
//

import Testing
import Foundation
@testable import PodcastAIKit

private func id(_ raw: String) -> EpisodeID { EpisodeID(rawValue: raw) }

/// Schreibt jeden Stand mit und prüft, dass keiner kleiner ist als der vorige.
private struct Recorder {
    var progress = BackgroundRunProgress()
    var seen: [Int64] = []

    mutating func record() {
        seen.append(progress.completedUnitCount)
        #expect(progress.totalUnitCount > progress.completedUnitCount)
    }

    var isMonotonic: Bool { zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 } }
    var isStrictlyGrowing: Bool { zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 } }
}

@Suite("Fortschritt der Arbeit im Hintergrund")
struct BackgroundRunProgressTests {

    @Test("Drei Folgen mit Laden, Transkript, Fakten und Tags: der Stand wächst nur")
    func monotonicAcrossEpisodes() {
        var run = Recorder()
        run.progress.expect(.init(transcripts: 2, facts: 3, tags: 3))
        for name in ["a", "b", "c"] {
            let episode = id(name)
            for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                run.progress.report(.transcript, episode: episode, .download(step))
                run.record()
            }
            for step in stride(from: 0.0, through: 1.0, by: 0.1) {
                run.progress.report(.transcript, episode: episode, .transcription(step))
                run.record()
            }
            run.progress.report(.transcript, episode: episode, .transcribed)
            run.record()
            for step in stride(from: 0.0, through: 1.0, by: 0.2) {
                run.progress.report(.facts, episode: episode, .facts(step))
                run.record()
            }
            for step in stride(from: 0.0, through: 1.0, by: 0.5) {
                run.progress.report(.tags, episode: episode, .tags(step))
                run.record()
            }
        }
        run.progress.finishCurrent()
        run.record()
        #expect(run.isMonotonic)
        let perEpisode = BackgroundRunProgress.Step.allCases.map(\.weight).reduce(0, +)
        #expect(run.progress.completedUnitCount == 3 * perEpisode)
    }

    @Test("Eine neue Folge beginnt nicht wieder vorn")
    func newEpisodeDoesNotRestart() {
        var progress = BackgroundRunProgress()
        progress.report(.transcript, episode: id("a"), .transcription(0.9))
        let before = progress.completedUnitCount
        progress.report(.transcript, episode: id("b"), .download(0))
        #expect(progress.completedUnitCount >= before)
        #expect(progress.completedUnitCount == BackgroundRunProgress.Step.transcript.weight)
    }

    @Test("Innerhalb eines Schritts geht eine kleinere Meldung nicht zurück")
    func smallerReportIsIgnored() {
        var progress = BackgroundRunProgress()
        progress.report(.transcript, episode: id("a"), .transcription(0.6))
        let before = progress.completedUnitCount
        progress.report(.transcript, episode: id("a"), .download(1))
        progress.report(.transcript, episode: id("a"), .transcription(0.2))
        #expect(progress.completedUnitCount == before)
    }

    @Test("Laden kommt vor dem Transkript, Fakten vor den Tags, jeder Teil zählt")
    func phaseOrdering() {
        typealias Phase = BackgroundRunProgress.Phase
        #expect(Phase.download(1).value <= Phase.transcription(0).value)
        #expect(Phase.transcription(1).value <= Phase.transcribed.value)
        #expect(Phase.transcribed.value < 1)
        #expect(Phase.download(0.5).value > Phase.download(0.1).value)
        #expect(Phase.facts(0.5).value > Phase.facts(0.25).value)
        var progress = BackgroundRunProgress()
        progress.report(.facts, episode: id("a"), .facts(1))
        let facts = progress.completedUnitCount
        progress.report(.tags, episode: id("a"), .tags(0))
        #expect(progress.completedUnitCount == BackgroundRunProgress.Step.facts.weight)
        #expect(progress.completedUnitCount > facts)
    }

    @Test("Kommen Folgen dazu, wächst die Gesamtzahl, der Stand bleibt")
    func addedWorkGrowsTotal() {
        var progress = BackgroundRunProgress()
        progress.expect(.init(transcripts: 1))
        progress.report(.transcript, episode: id("a"), .transcription(0.5))
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount
        progress.expect(.init(transcripts: 4, facts: 5, tags: 5))
        #expect(progress.completedUnitCount == completed)
        #expect(progress.totalUnitCount > total)
        // Weniger erwartet als gedacht: Die Gesamtzahl bleibt über dem Stand.
        progress.expect(.init())
        progress.finishCurrent()
        #expect(progress.totalUnitCount > progress.completedUnitCount)
    }

    @Test("Ein langer Schritt ohne Meldung rückt vor, erreicht die Grenze aber nie")
    func creepStaysBelowCeiling() {
        var run = Recorder()
        run.progress.report(.facts, episode: id("a"), .facts(0.2))
        run.record()
        // Kurz nach der Meldung bewegt sich nichts.
        run.progress.tick(seconds: BackgroundRunProgress.creepDelay / 2)
        #expect(run.progress.completedUnitCount == run.seen.last)
        // Zehn Minuten ohne Meldung, im Takt des Herzschlags.
        for _ in 0..<120 {
            run.progress.tick(seconds: BackgroundRunProgress.creepInterval)
            run.record()
        }
        #expect(run.isMonotonic)
        #expect(run.progress.fraction < 1)
        #expect(run.progress.completedUnitCount < BackgroundRunProgress.Step.facts.weight)
        #expect(run.progress.completedUnitCount > run.seen[0])
        // In den ersten Minuten wächst der Stand mit jedem Takt.
        var early = Recorder()
        early.progress.report(.transcript, episode: id("b"), .download(0.1))
        early.progress.tick(seconds: BackgroundRunProgress.creepDelay)
        for _ in 0..<60 {
            early.progress.tick(seconds: BackgroundRunProgress.creepInterval)
            early.record()
        }
        #expect(early.isStrictlyGrowing)
        #expect(early.progress.fraction < BackgroundRunProgress.Phase.download(1).value)
    }

    @Test("Eine echte Meldung übernimmt wieder, das Aufrücken beginnt neu")
    func realReportResetsCreep() {
        var progress = BackgroundRunProgress()
        progress.report(.transcript, episode: id("a"), .transcription(0.1))
        for _ in 0..<20 { progress.tick(seconds: BackgroundRunProgress.creepInterval) }
        let crept = progress.completedUnitCount
        progress.report(.transcript, episode: id("a"), .transcription(0.5))
        let reported = progress.completedUnitCount
        #expect(reported > crept)
        // Gleich nach der Meldung wartet das Aufrücken wieder.
        progress.tick(seconds: BackgroundRunProgress.creepInterval)
        #expect(progress.completedUnitCount == reported)
    }

    @Test("Ohne laufenden Schritt bewegt sich nichts")
    func noCreepWithoutStep() {
        var progress = BackgroundRunProgress()
        progress.expect(.init(transcripts: 2))
        for _ in 0..<50 { progress.tick(seconds: BackgroundRunProgress.creepInterval) }
        #expect(progress.completedUnitCount == 0)
        progress.report(.tags, episode: id("a"), .tags(0.5))
        progress.finishCurrent()
        let finished = progress.completedUnitCount
        for _ in 0..<50 { progress.tick(seconds: BackgroundRunProgress.creepInterval) }
        #expect(progress.completedUnitCount == finished)
    }

    @Test("Ein fertiger Schritt zählt voll, auch wenn die letzte Meldung kleiner war")
    func finishCountsFullWeight() {
        var progress = BackgroundRunProgress()
        progress.report(.facts, episode: id("a"), .facts(0.3))
        progress.finishCurrent()
        #expect(progress.completedUnitCount == BackgroundRunProgress.Step.facts.weight)
        progress.report(.tags, episode: id("a"), .tags(0.1))
        progress.report(.transcript, episode: id("b"), .download(0))
        #expect(progress.completedUnitCount
            == BackgroundRunProgress.Step.facts.weight + BackgroundRunProgress.Step.tags.weight)
    }

    @Test("Unsinnige Anteile zählen als nichts oder als ganz")
    func clampsFractions() {
        var progress = BackgroundRunProgress()
        progress.report(.facts, episode: id("a"), .facts(.nan))
        #expect(progress.completedUnitCount == 0)
        progress.report(.facts, episode: id("a"), .facts(7))
        #expect(progress.fraction == BackgroundRunProgress.Phase.facts(1).value)
        progress.report(.facts, episode: id("a"), .facts(-3))
        #expect(progress.fraction == BackgroundRunProgress.Phase.facts(1).value)
    }
}

@Suite("Wann die fortgesetzte Verarbeitung gebraucht wird")
struct BackgroundWorkLoadTests {

    @Test("Transkripte tragen immer, Fakten und Tags nur, wenn ein Modell da ist")
    func hasWork() {
        #expect(!BackgroundWorkLoad().hasWork)
        #expect(BackgroundWorkLoad(transcriptRunning: true).hasWork)
        #expect(BackgroundWorkLoad(transcriptsQueued: 1, knowledgeWaiting: true).hasWork)
        #expect(BackgroundWorkLoad(factsQueued: 2).hasWork)
        #expect(BackgroundWorkLoad(tagsRunning: true).hasWork)
        #expect(!BackgroundWorkLoad(factsRunning: true, factsQueued: 3, tagsQueued: 4, knowledgeWaiting: true).hasWork)
    }

    @Test("Auf Transkripte folgen Fakten und Tags, auf Fakten die Tags")
    func expectedFollowUps() {
        let load = BackgroundWorkLoad(transcriptRunning: true, transcriptsQueued: 2, factsQueued: 1, tagsQueued: 3)
        #expect(load.expected == .init(transcripts: 2, facts: 4, tags: 7))
        var manual = load
        manual.automaticFacts = false
        #expect(manual.expected == .init(transcripts: 2, facts: 1, tags: 4))
        let facts = BackgroundWorkLoad(factsRunning: true)
        #expect(facts.expected == .init(transcripts: 0, facts: 0, tags: 1))
    }
}
