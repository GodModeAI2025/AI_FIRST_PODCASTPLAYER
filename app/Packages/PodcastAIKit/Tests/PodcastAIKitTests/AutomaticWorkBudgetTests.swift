//
//  AutomaticWorkBudgetTests.swift
//  PodcastAIKitTests
//
//  Automatisches kommt in kleinen Portionen, Angefordertes bleibt.
//

import Testing
@testable import PodcastAIKit

@Suite("Portionen für automatische Arbeit")
struct AutomaticWorkBudgetTests {

    @Test("Im Akku wenige ältere Folgen, am Strom und auf dem Mac mehr")
    func backCatalogBatch() {
        #expect(AutomaticWorkBudget.backCatalogBatch(charging: false, isMac: false) == 3)
        #expect(AutomaticWorkBudget.backCatalogBatch(charging: true, isMac: false) == 10)
        #expect(AutomaticWorkBudget.backCatalogBatch(charging: false, isMac: true) == 10)
    }

    @Test("Nachfüllen bis zur Portion, neueste zuerst")
    func refill() {
        let candidates = Array(1...591)
        #expect(AutomaticWorkBudget.refill(candidates, alreadyWaiting: 0, batch: 10) == Array(1...10))
        #expect(AutomaticWorkBudget.refill(candidates, alreadyWaiting: 7, batch: 10) == [1, 2, 3])
        #expect(AutomaticWorkBudget.refill(candidates, alreadyWaiting: 12, batch: 10).isEmpty)
        #expect(AutomaticWorkBudget.refill([Int](), alreadyWaiting: 0, batch: 10).isEmpty)
    }

    @Test("Eine gesicherte Warteschlange verliert nur ältere Folgen über der Portion")
    func trimmedKeepsRequested() {
        struct Item: Equatable { let id: Int; let source: String; let backlog: Bool }
        var queue = [Item(id: 0, source: "a", backlog: false)]
        queue += (1...200).map { Item(id: $0, source: $0.isMultiple(of: 2) ? "a" : "b", backlog: true) }
        queue.append(Item(id: 999, source: "a", backlog: false))
        let trimmed = AutomaticWorkBudget.trimmed(queue, isBacklog: \.backlog, group: \.source, batch: 3)
        #expect(trimmed.map(\.id) == [0, 1, 2, 3, 4, 5, 6, 999])
    }
}
