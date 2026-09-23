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

    /// Leere Mediathek, Leiste und Hinzufügen-Blatt bieten den Import an.
    func testImportEntryPoints() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        tab(app, "Mediathek")
        XCTAssertTrue(app.buttons["Abos aus Datei importieren"].firstMatch.waitForExistence(timeout: 10),
                      "Die leere Mediathek bietet keinen Import an")
        XCTAssertTrue(app.navigationBars.buttons["Abos importieren oder exportieren"].firstMatch.exists,
                      "Import und Export fehlen in der Leiste")
        app.navigationBars.buttons["Quelle hinzufügen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["source.importOPML"].waitForExistence(timeout: 5),
                      "Das Hinzufügen-Blatt bietet keinen Import an")
    }

    /// Ein geteilter @-Link wird über die Kanalseite aufgelöst.
    func testYouTubeHandleLinkAddsChannel() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        tab(app, "Mediathek")
        app.navigationBars.buttons["Quelle hinzufügen"].firstMatch.tap()
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://youtube.com/@mkbhd?si=uitest")
        app.buttons["source.addLink"].tap()
        XCTAssertTrue(app.staticTexts["Marques Brownlee"].firstMatch.waitForExistence(timeout: 45),
                      "Der Kanal aus dem @-Link fehlt in der Mediathek")
    }
}
