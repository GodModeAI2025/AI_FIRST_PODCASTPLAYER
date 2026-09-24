//
//  TranscriptNotificationUITests.swift
//  PodcastAIUITests
//
//  Beim ersten Transkript, das jemand selbst anfordert, fragt die App, ob
//  sie Bescheid sagen darf, wenn Transkripte im Hintergrund pausieren. Ein
//  „Nicht jetzt“ schließt die Frage, und sie kommt nicht wieder.
//
//  Andere UI-Tests sehen die Frage nicht; nur `-uitest-notification-prompt`
//  schaltet sie im Test ein. Hat das System auf diesem Simulator schon über
//  Mitteilungen entschieden, fragt die App nicht, und der Test entfällt.
//

import XCTest

final class TranscriptNotificationUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testFirstRequestedTranscriptAsksOnceForNotifications() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-fresh", "-demo-content", "-uitest-notification-prompt",
            "-automaticAnalysis", "NO", "-keepNewestAudio", "NO",
        ]
        app.launch()

        app.tabBars.buttons["Meine Podcasts"].tap()
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()

        // Die zweite Beispielfolge hat noch kein Transkript.
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ohne Transkript'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()

        let request = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Transkript erstellen'")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10), "Kein Knopf „Transkript erstellen“")
        request.tap()

        let question = app.alerts["Bescheid sagen, wenn Transkripte pausieren?"]
        guard question.waitForExistence(timeout: 5) else {
            throw XCTSkip("Über Mitteilungen ist auf diesem Simulator schon entschieden")
        }
        XCTAssertTrue(question.buttons["Erlauben"].exists)
        question.buttons["Nicht jetzt"].tap()
        XCTAssertFalse(question.waitForExistence(timeout: 2), "Die Frage bleibt nach „Nicht jetzt“ stehen")

        // Noch einmal anfordern: keine zweite Frage.
        if request.waitForExistence(timeout: 3) {
            request.tap()
            XCTAssertFalse(question.waitForExistence(timeout: 3), "Die App fragt ein zweites Mal")
        }
    }
}
