//
//  TranscriptSearchUITests.swift
//  PodcastAIUITests
//
//  Die Suche im Reiter „Transkript“ muss die Zeilen filtern.
//

import XCTest

@MainActor
final class TranscriptSearchUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSearchFiltersTranscriptLines() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        let tabButton = app.tabBars.buttons["Meine Podcasts"]
        (tabButton.exists ? tabButton : app.buttons["Meine Podcasts"].firstMatch).tap()
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()
        let sections = app.segmentedControls["episode.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        sections.buttons["Transkript"].tap()

        let field = app.textFields["transcript.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Kein Suchfeld im Transkript")
        let lines = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}.*'"))
        let before = lines.count
        attach(app, "vorher")
        field.tap()
        field.typeText("Musterstraße")
        let hit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Musterstraße'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "Die Suche zeigt den Treffer nicht")
        attach(app, "nachher")
        XCTAssertLessThan(lines.count, before, "Die Suche filtert nicht: \(before) Zeilen vorher, \(lines.count) nachher")
    }
}
