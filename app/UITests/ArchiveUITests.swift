//
//  ArchiveUITests.swift
//  PodcastAIUITests
//
//  Ältere Folgen: Kopfzeile mit beiden Zahlen, Filter und Reihenfolge,
//  Auswahlmodus und Suche in der Folgenliste eines Podcasts. Der Test reiht
//  nichts ein, damit im Simulator keine Downloads anlaufen.
//

import XCTest

final class ArchiveUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private let feed = "https://feeds.transistor.fm/ai-to-the-dna"

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFindAndSelectOlderEpisodes() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        let library = app.tabBars.buttons["Meine Podcasts"]
        (library.exists ? library : app.buttons["Meine Podcasts"].firstMatch).tap()
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(feed)
        app.buttons["Hinzufügen"].tap()
        let row = app.staticTexts["AI to the DNA"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()

        // Die Kopfzeile nennt gefundene Folgen und Folgen mit Transkript getrennt.
        let coverage = app.descendants(matching: .any)["episodes.coverage"]
        XCTAssertTrue(coverage.waitForExistence(timeout: 15), "Keine Kopfzeile über den Folgen")
        XCTAssertTrue(coverage.label.contains(" von "), "Kopfzeile ohne Gesamtzahl: \(coverage.label)")
        XCTAssertTrue(coverage.label.contains("mit Transkript"), "Kopfzeile ohne Folgen mit Transkript: \(coverage.label)")

        // Filter und Reihenfolge.
        app.buttons["episodes.filter"].tap()
        let oldest = app.buttons["Älteste zuerst"].firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "Reihenfolge fehlt im Menü")
        oldest.tap()
        attach(app, "aelteste-zuerst")

        // Auswahlmodus: ohne Auswahl ist der Knopf aus, mit Auswahl an.
        app.buttons["episodes.select"].tap()
        let analyze = app.buttons["episodes.analyzeSelection"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5), "Kein Knopf „Transkripte erstellen“")
        XCTAssertFalse(analyze.isEnabled, "Ohne Auswahl darf nichts eingereiht werden")
        app.buttons["Alle auswählen"].tap()
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: analyze)
        wait(for: [enabled], timeout: 5)
        attach(app, "auswahl")
        app.buttons["episodes.select"].tap()
        XCTAssertTrue(analyze.waitForNonExistence(timeout: 5), "Auswahlmodus bleibt offen")

        // Suche über Titel und Shownotes.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Keine Suche in der Folgenliste")
        search.tap()
        search.typeText("qxzvnichtvorhanden")
        XCTAssertTrue(app.staticTexts["Keine Treffer"].waitForExistence(timeout: 10), "Leere Suche ohne Hinweis")
        attach(app, "keine-treffer")
    }
}
