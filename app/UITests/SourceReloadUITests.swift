//
//  SourceReloadUITests.swift
//  PodcastAIUITests
//
//  „Neu laden“ für eine einzelne Quelle: im Kontextmenü unter „Meine
//  Podcasts“ und auf der Seite der Quelle. Läuft mit `-catalog-fixtures`
//  ohne Netz; der Feed kommt dann aus den festen Beispielen.
//

import XCTest

final class SourceReloadUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Holt eine einzelne Folge aus dem Katalog. Danach steht ihr Podcast
    /// mit Feed, aber ohne Abo unter „Meine Podcasts“.
    @MainActor private func addSourceFromCatalog() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-catalog-fixtures", "-automaticAnalysis", "NO"]
        app.launch()
        let tabButton = app.tabBars.buttons["Meine Podcasts"]
        (tabButton.exists ? tabButton : app.buttons["Meine Podcasts"].firstMatch).tap()
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()

        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("kaffee")
        let row = app.buttons.matching(identifier: "catalog.row")
            .matching(NSPredicate(format: "label CONTAINS 'Code und Kaffee'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Kein Treffer aus der Suche")
        row.tap()
        let single = app.buttons["episode.single"].firstMatch
        var attempts = 6
        while !(single.exists && single.isHittable) && attempts > 0 {
            app.swipeUp()
            attempts -= 1
        }
        XCTAssertTrue(single.exists, "Neben den Folgen fehlt „Nur diese Folge“")
        single.tap()
        let added = app.descendants(matching: .any)["episode.single.done"].firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10), "Die Folge wurde nicht geholt")

        let back = app.navigationBars.buttons["Hinzufügen"].firstMatch
        if back.exists { back.tap() }
        let done = app.navigationBars.buttons["Fertig"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "„Fertig“ fehlt nach dem Holen")
        done.tap()
        return app
    }

    @MainActor func testReloadSingleSource() {
        let app = addSourceFromCatalog()
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Code und Kaffee'")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Der Podcast fehlt unter „Meine Podcasts“")

        // Kontextmenü der Quelle: „Neu laden“ steht dort.
        source.press(forDuration: 1.2)
        let menuReload = app.buttons["source.reload"].firstMatch
        XCTAssertTrue(menuReload.waitForExistence(timeout: 5), "Im Kontextmenü fehlt „Neu laden“")
        attach(app, "kontextmenue")
        menuReload.tap()

        // Die Seite der Quelle: Knopf in der Leiste, danach eine ruhige Zeile.
        source.tap()
        XCTAssertTrue(app.buttons["source.subscribe"].waitForExistence(timeout: 10),
                      "Die Seite der Quelle öffnet nicht")
        let reload = app.buttons["source.reload"].firstMatch
        XCTAssertTrue(reload.waitForExistence(timeout: 5), "Auf der Seite fehlt „Neu laden“")
        reload.tap()
        let status = app.descendants(matching: .any)["source.reloadStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "Nach dem Neuladen steht kein Ergebnis da")
        XCTAssertTrue(status.label.hasPrefix("Neu geladen"), "Unerwartet: \(status.label)")
        attach(app, "neu-geladen")

        // Neu laden macht aus der Quelle kein Abo.
        XCTAssertTrue(app.buttons["source.subscribe"].exists, "Nach dem Neuladen ist die Quelle abonniert")
    }
}
