//
//  QueueControlTests.swift
//  PodcastAIKitTests
//
//  Pausieren und „Alle abbrechen“ der Warteschlange als reine Regeln.
//

import Testing
import Foundation
@testable import PodcastAIKit

private func id(_ raw: String) -> EpisodeID { EpisodeID(rawValue: raw) }

@Suite("Warteschlange pausieren und abbrechen")
struct QueueControlTests {

    @Test("Pausiert beginnt nichts, auch nicht vorn")
    func pausedStartsNothing() {
        #expect(AnalysisQueueControl.mayStart(paused: false, inForeground: true, cancelling: false))
        #expect(!AnalysisQueueControl.mayStart(paused: true, inForeground: true, cancelling: false))
        #expect(!AnalysisQueueControl.mayStart(paused: false, inForeground: false, cancelling: false))
        #expect(!AnalysisQueueControl.mayStart(paused: false, inForeground: true, cancelling: true))
    }

    @Test("Wartende Folgen zählen Transkripte, Fakten und die angehaltene Folge")
    func waitingCountAddsUp() {
        #expect(AnalysisQueueControl.waitingCount(running: false, transcripts: 0, facts: 0) == 0)
        #expect(AnalysisQueueControl.waitingCount(running: true, transcripts: 10, facts: 1) == 12)
        #expect(AnalysisQueueControl.waitingCount(running: false, transcripts: -3, facts: 2) == 2)
    }

    @Test("Alle abbrechen nimmt jede Folge einmal, die laufende zuerst")
    func cancelAllRemovesEverythingOnce() {
        let plan = AnalysisQueueControl.cancelAll(
            running: id("b"), queue: [id("a"), id("b"), id("c")], automatic: [])
        #expect(plan.removed == [id("b"), id("a"), id("c")])
        #expect(plan.stopsRunning)
        #expect(plan.restingUntilRefresh.isEmpty)
    }

    @Test("Nur von selbst Eingereihtes ruht bis zum nächsten Aktualisieren")
    func onlyAutomaticItemsRest() {
        let plan = AnalysisQueueControl.cancelAll(
            running: nil, queue: [id("hand"), id("auto1"), id("auto2")],
            automatic: [id("auto1"), id("auto2"), id("fremd")])
        #expect(plan.restingUntilRefresh == [id("auto1"), id("auto2")])
        #expect(!plan.stopsRunning)
    }

    @Test("Eine leere Warteschlange bleibt leer")
    func cancelAllOnEmptyQueue() {
        let plan = AnalysisQueueControl.cancelAll(running: nil, queue: [], automatic: [id("x")])
        #expect(plan.removed.isEmpty)
        #expect(plan.restingUntilRefresh.isEmpty)
        #expect(!plan.stopsRunning)
    }
}
