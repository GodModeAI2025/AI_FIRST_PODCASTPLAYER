//
//  GoalFeaturesUITests.swift
//  PodcastAIUITests
//
//  Die Kernwege der App: Folge mit Reitern, Fragen an eine Folge, Export,
//  Löschen, Einstellungen für Intelligenz, Speicher und Synchronisation.
//

import XCTest

final class GoalFeaturesUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private let feed = "https://feeds.transistor.fm/ai-to-the-dna"

    private func launchWithFeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        app.tabBars.buttons["Mediathek"].tap()
        app.navigationBars.buttons["Quelle hinzufügen"].firstMatch.tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(feed)
        app.buttons["Hinzufügen"].tap()
        let row = app.staticTexts["AI to the DNA"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testEpisodeSectionsAndEpisodeChat() {
        let app = launchWithFeed()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 15))
        episode.tap()

        let sections = app.segmentedControls["episode.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        for name in ["Kapitel", "Transkript", "Fakten"] {
            sections.buttons[name].tap()
            attach(app, "reiter-\(name)")
        }
        sections.buttons["Fragen"].tap()
        let suggestion = app.buttons["Worum geht es in dieser Folge?"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Keine Vorschlagsfragen")
        suggestion.tap()
        // Im Simulator ist die Folge nicht erschlossen. Die Antwort sagt das.
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'erschlossen'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20), "Keine Antwort im Folgen-Chat")
        attach(app, "folgen-chat")
    }

    func testEpisodeExportAndDelete() {
        let app = launchWithFeed()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 15))
        let title = episode.buttons.firstMatch.label
        episode.tap()

        let menu = app.buttons["episode.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Exportieren ohne Transkript"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 10), "Kein Export")
        attach(app, "export")
        app.buttons["Fertig"].firstMatch.tap()

        menu.tap()
        app.buttons["Folge löschen"].tap()
        let confirm = app.buttons["Folge und alle Daten löschen"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Zurück in der Liste, die Folge ist weg.
        let prefix = String(title.prefix(40))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        let deadline = Date().addingTimeInterval(10)
        while row.exists && Date() < deadline { sleep(1) }
        XCTAssertFalse(row.exists, "Folge ist nach dem Löschen noch da")
        attach(app, "geloescht")
    }

    func testSettingsShowIntelligenceStorageAndSync() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        app.tabBars.buttons["Wissen"].tap()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Einstellungen'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.switches["Private Cloud Compute nutzen"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.staticTexts["Audiodateien auf diesem Gerät"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Audiodateien auf diesem Gerät"].exists)
        XCTAssertTrue(app.staticTexts["iCloud"].exists)
        attach(app, "einstellungen")
    }
}
