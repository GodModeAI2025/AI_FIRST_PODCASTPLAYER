//
//  TranscriptSearchUITests.swift
//  PodcastAIUITests
//
//  Die Suche im Reiter „Transkript“ muss die Zeilen filtern, die Zahl der
//  Treffer nennen und sagen, wenn nichts passt.
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

    /// Öffnet das Transkript der Beispielfolge und gibt das Suchfeld zurück.
    private func openTranscript(_ app: XCUIApplication) -> XCUIElement {
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
        return field
    }

    /// Jede Zeile trägt die Kennung `transcript.line`. Nach Zeitcodes im
    /// Namen zu suchen fand nichts: VoiceOver liest sie ausgeschrieben.
    private func lines(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "transcript.line")
    }

    func testSearchFiltersTranscriptLines() {
        let app = XCUIApplication()
        let field = openTranscript(app)
        XCTAssertTrue(lines(app).firstMatch.waitForExistence(timeout: 10), "Keine Zeilen im Transkript")
        let before = lines(app).count
        XCTAssertGreaterThan(before, 1)
        attach(app, "vorher")

        field.tap()
        // Klein und ohne „ß“: die Suche faltet beides.
        field.typeText("musterstrasse")
        let hits = app.descendants(matching: .any)["transcript.hits"].firstMatch
        XCTAssertTrue(hits.waitForExistence(timeout: 5), "Keine Zeile mit der Zahl der Treffer")
        XCTAssertEqual(hits.label, "1 Treffer")
        let hit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Musterstraße'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "Die Suche zeigt den Treffer nicht")
        XCTAssertTrue(hit.isHittable, "Der Treffer liegt außerhalb des Bildes")
        attach(app, "nachher")
        XCTAssertEqual(lines(app).count, 1, "Die Suche filtert nicht: \(before) Zeilen vorher, \(lines(app).count) nachher")
    }

    func testSearchWithoutMatchesSaysSo() {
        let app = XCUIApplication()
        let field = openTranscript(app)
        XCTAssertTrue(lines(app).firstMatch.waitForExistence(timeout: 10), "Keine Zeilen im Transkript")

        field.tap()
        field.typeText("  xylophon  ")
        let hits = app.descendants(matching: .any)["transcript.hits"].firstMatch
        XCTAssertTrue(hits.waitForExistence(timeout: 5), "Kein Hinweis, dass nichts gefunden wurde")
        XCTAssertTrue(hits.label.hasPrefix("Keine Treffer für „xylophon“"), "Unerwartet: \(hits.label)")
        XCTAssertEqual(lines(app).count, 0)
        attach(app, "keine-treffer")
    }
}
