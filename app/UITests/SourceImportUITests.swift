//
//  SourceImportUITests.swift
//  PodcastAIUITests
//
//  Abos mitbringen: der Import einer OPML-Datei muss dort zu finden sein,
//  wo man anfängt, und ein geteilter YouTube-Link mit Kanalnamen
//  (`youtube.com/@name?si=…`) legt den Kanal an statt einer Fehlermeldung.
//  YouTube-Abos aus Google Takeout zeigen, welche Kanäle einen Audio-Podcast
//  haben; mit `-takeout-fixture` und `-catalog-fixtures` ohne Dateiauswahl
//  und ohne Netz.
//

import XCTest

final class SourceImportUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    /// Leere Liste „Meine Podcasts“ und Leiste bieten den Import an, das Hinzufügen-Blatt nicht mehr.
    func testImportEntryPoints() {
        let app = XCUIApplication()
        // Die Charts kommen aus den Beispielen, sonst hinge der Test an Apples Server.
        app.launchArguments = ["-uitest-fresh", "-catalog-fixtures"]
        app.launch()
        tab(app, "Meine Podcasts")
        XCTAssertTrue(app.buttons["Abos aus Datei importieren"].firstMatch.waitForExistence(timeout: 10),
                      "Die leere Liste „Meine Podcasts“ bietet keinen Import an")
        XCTAssertTrue(app.navigationBars.buttons["Abos importieren oder exportieren"].firstMatch.exists,
                      "Import und Export fehlen in der Leiste")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["catalog.trending.card"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["source.importOPML"].exists, "Das Hinzufügen-Blatt zeigt noch den Import")
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

    /// Takeout-Liste: zwei von drei Kanälen haben einen Audio-Podcast, beide sind vorgewählt.
    @MainActor func testTakeoutImportRecommendsAudioPodcasts() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-catalog-fixtures", "-takeout-fixture"]
        app.launch()
        tab(app, "Meine Podcasts")
        let menu = app.navigationBars.buttons["Abos importieren oder exportieren"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Import und Export fehlen in der Leiste")
        menu.tap()
        let entry = app.buttons["YouTube-Abos aus Google Takeout importieren"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Der Import aus Google Takeout fehlt im Menü")
        entry.tap()

        let werkstatt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Werkstatt, ohne Ton")).firstMatch
        XCTAssertTrue(werkstatt.waitForExistence(timeout: 10), "Die Kanäle aus der Datei fehlen")
        XCTAssertTrue(app.descendants(matching: .any)["takeout.searchSummary"].waitForExistence(timeout: 20),
                      "Die Suche nach Audio-Podcasts endet nicht")
        let recommended = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio-Podcast verfügbar"))
        XCTAssertEqual(recommended.count, 2, "Zwei Kanäle haben laut Verzeichnis einen Audio-Podcast")
        XCTAssertTrue(werkstatt.label.contains("Kein Audio-Podcast gefunden"))

        let subscribe = app.buttons["takeout.subscribe"]
        XCTAssertTrue(subscribe.isEnabled)
        XCTAssertEqual(subscribe.label, "2 abonnieren")
        app.buttons["takeout.selectionMenu"].tap()
        app.buttons["Alle abwählen"].firstMatch.tap()
        XCTAssertFalse(subscribe.isEnabled, "Ohne Auswahl lässt sich nichts abonnieren")
        werkstatt.tap()
        XCTAssertEqual(subscribe.label, "1 abonnieren")
        app.navigationBars.buttons["Abbrechen"].firstMatch.tap()
        XCTAssertFalse(subscribe.waitForExistence(timeout: 2))
    }
}
