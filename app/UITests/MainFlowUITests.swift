//
//  MainFlowUITests.swift
//  PodcastAIUITests
//
//  Der Hauptweg auf echtem Netz: Podcast hinzufügen, er erscheint unter
//  Meine Podcasts, seine Folgen lassen sich öffnen. Dazu ein Durchgang
//  durch alle Tabs, damit keine Ansicht beim ersten Öffnen abstürzt.
//

import XCTest

final class MainFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testAllTabsOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launch()
        for tab in ["Themen-Updates", "Meine Podcasts", "Wissen", "Für dich"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.state == .runningForeground, "Absturz beim Öffnen von \(tab)")
        }
        app.tabBars.buttons["Chat"].firstMatch.tap()
        XCTAssertTrue(app.state == .runningForeground)
    }

    func testAddFeedShowsSourceAndEpisodes() {
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launch()
        app.tabBars.buttons["Meine Podcasts"].tap()

        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://feeds.npr.org/510289/podcast.xml")
        app.buttons["Hinzufügen"].tap()

        let row = app.staticTexts["Planet Money"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Der Podcast erscheint nicht unter Meine Podcasts")
        row.tap()

        // Mindestens eine Folgenzeile muss erscheinen.
        let anyCell = app.cells.element(boundBy: 0)
        XCTAssertTrue(anyCell.waitForExistence(timeout: 15), "Keine Folgen sichtbar")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Download, Transkription und Belegextraktion einer echten Folge.
    /// Läuft mehrere Minuten; nur mit RUN_ANALYSIS=1 in der Umgebung.
    func testAnalyzeEpisode() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_ANALYSIS"] == "1"
                          || ProcessInfo.processInfo.environment["RUN_ANALYSIS"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-skip-onboarding"]
        app.launch()
        app.tabBars.buttons["Meine Podcasts"].tap()
        let row = app.staticTexts["Planet Money"].firstMatch
        if !row.waitForExistence(timeout: 5) {
            app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
            let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            field.tap()
            field.typeText("https://feeds.npr.org/510289/podcast.xml")
            app.buttons["Hinzufügen"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 30))
        }
        row.tap()
        // Die Folge öffnen: „Transkript erstellen“ sitzt in der Folgenansicht.
        let firstEpisode = app.cells.element(boundBy: 1)
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 15))
        firstEpisode.tap()
        let analyze = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Transkript erstellen'")).firstMatch
        XCTAssertTrue(analyze.waitForExistence(timeout: 15), "Kein Knopf „Transkript erstellen“")
        analyze.tap()

        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Transkript fertig'")).firstMatch
        let failed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fehlgeschlagen'")).firstMatch
        let alert = app.alerts.firstMatch
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if done.exists || failed.exists || alert.exists { break }
            sleep(5)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        if alert.exists { XCTFail("Fehlermeldung: \(alert.debugDescription)") }
        XCTAssertFalse(failed.exists, "Transkript fehlgeschlagen: \(failed.label)")
        XCTAssertTrue(done.exists, "Transkript nicht in 15 Minuten fertig")
    }
}
