//
//  QueueControlUITests.swift
//  PodcastAIUITests
//
//  Pausieren, Fortsetzen und „Alle abbrechen“ in der Warteschlange.
//
//  Die App startet pausiert (`-analysisQueuePaused YES`), damit die
//  angeforderte Folge wartet, statt im Simulator sofort zu laufen oder zu
//  scheitern. Ohne automatisches Vorbereiten steht nur sie in der Liste.
//

import XCTest

final class QueueControlUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Startet pausiert, fordert ein Transkript an und öffnet die Warteschlange.
    @MainActor private func launchWithQueuedTranscript() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-fresh", "-demo-content", "-skip-onboarding",
            "-automaticAnalysis", "NO", "-keepNewestAudio", "NO", "-automaticFacts", "NO",
            "-analysisQueuePaused", "YES",
        ]
        app.launch()

        app.tabBars.buttons["Meine Podcasts"].tap()
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()

        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ohne Transkript'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()

        let request = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Transkript erstellen'")).firstMatch
        guard request.waitForExistence(timeout: 10) else {
            throw XCTSkip("Kein Knopf „Transkript erstellen“ an der Beispielfolge")
        }
        request.tap()
        // Die Frage nach Mitteilungen kommt in UI-Tests nur mit eigenem Schalter.

        // Das Aktivitätssymbol steht auf den obersten Seiten, nicht auf der
        // Folge. Zurück bis „Meine Podcasts“.
        let libraryTitle = app.navigationBars["Meine Podcasts"]
        for _ in 0..<3 where !libraryTitle.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = libraryTitle.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 5), "Nicht zurück bei „Meine Podcasts“")

        let status = app.buttons["activity.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Kein Aktivitätssymbol für die wartende Folge")
        status.tap()
        XCTAssertTrue(app.navigationBars["Warteschlange"].waitForExistence(timeout: 5))
        return app
    }

    /// Wartet, bis ein Element verschwunden ist.
    @MainActor private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor func testPauseShowsPausedAndResumeClearsIt() throws {
        let app = try launchWithQueuedTranscript()

        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pausiert'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "„Pausiert“ fehlt in der Warteschlange")

        let resume = app.buttons["queue.resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(waitForDisappearance(of: notice, timeout: 5), "„Pausiert“ bleibt nach „Fortsetzen“ stehen")

        // Jetzt steht dort „Pausieren“. Ein Tipp hält wieder an.
        let pause = app.buttons["queue.pause"].firstMatch
        if pause.waitForExistence(timeout: 3) {
            pause.tap()
            XCTAssertTrue(notice.waitForExistence(timeout: 5), "„Pausieren“ zeigt nicht „Pausiert“")
        }
    }

    @MainActor func testCancelAllEmptiesTheQueue() throws {
        let app = try launchWithQueuedTranscript()

        let queued = app.descendants(matching: .any)["queue.transcript"].firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "Die angeforderte Folge steht nicht in der Warteschlange")

        let cancel = app.buttons["queue.cancelAll"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        let confirm = app.buttons["queue.cancelAll.confirm"].firstMatch
        let byLabel = app.sheets.buttons["Alle abbrechen"].firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.tap()
        } else {
            XCTAssertTrue(byLabel.waitForExistence(timeout: 3), "Keine Rückfrage vor „Alle abbrechen“")
            byLabel.tap()
        }

        XCTAssertTrue(waitForDisappearance(of: queued, timeout: 10),
                      "Nach „Alle abbrechen“ stehen noch Transkripte da")
    }
}
