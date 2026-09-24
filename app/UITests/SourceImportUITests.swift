//
//  SourceImportUITests.swift
//  PodcastAIUITests
//
//  Abos mitbringen: der Import einer OPML-Datei muss dort zu finden sein,
//  wo man anfängt, und ein geteilter YouTube-Link mit Kanalnamen
//  (`youtube.com/@name?si=…`) legt den Kanal an statt einer Fehlermeldung.
//

import XCTest

final class SourceImportUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    /// Leere Liste „Meine Podcasts“, Leiste und Hinzufügen-Blatt bieten den Import an.
    func testImportEntryPoints() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        tab(app, "Meine Podcasts")
        XCTAssertTrue(app.buttons["Abos aus Datei importieren"].firstMatch.waitForExistence(timeout: 10),
                      "Die leere Liste „Meine Podcasts“ bietet keinen Import an")
        XCTAssertTrue(app.navigationBars.buttons["Abos importieren oder exportieren"].firstMatch.exists,
                      "Import und Export fehlen in der Leiste")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["source.importOPML"].waitForExistence(timeout: 5),
                      "Das Hinzufügen-Blatt bietet keinen Import an")
    }

    /// Ein geteilter @-Link wird über die Kanalseite aufgelöst.
    @MainActor func testYouTubeHandleLinkAddsChannel() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        tab(app, "Meine Podcasts")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://youtube.com/@mkbhd?si=uitest")
        app.buttons["source.addLink"].tap()
        // Erst die Vorschau des Kanals, dann abonnieren.
        let channel = app.buttons["youtube.subscribeChannel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 45), "Keine Vorschau zum @-Link")
        channel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["youtube.subscribeChannel.done"].waitForExistence(timeout: 45))
        // Zurück aus der Vorschau, dann schließt „Fertig“ das Blatt.
        let back = app.navigationBars.buttons["Hinzufügen"].firstMatch
        if back.exists { back.tap() }
        let done = app.navigationBars.buttons["Fertig"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "„Fertig“ fehlt nach dem Abonnieren")
        done.tap()
        XCTAssertTrue(app.staticTexts["Marques Brownlee"].firstMatch.waitForExistence(timeout: 45),
                      "Der Kanal aus dem @-Link fehlt unter Meine Podcasts")
    }
}
