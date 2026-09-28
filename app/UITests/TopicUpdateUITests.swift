//
//  TopicUpdateUITests.swift
//  PodcastAIUITests
//
//  Themen-Updates seit 0.11: Tags als Kapseln, „alle zusammen“, eine Ausgabe
//  je Lauf wie eine Folge, die Übersicht als Kapitel 0 und kein Ton ohne Tipp.
//
//  Grundlage sind die Beispieldaten (`-demo-content`): eine Folge mit vier
//  Kapiteln. „Datenschutz und Modelle“ trägt Datenschutz und Sprachmodelle,
//  „Regeln im Team“ Automatisierung, „Haftung und Verordnung“ Haftung und
//  KI-Verordnung. Nur Datenschutz ist gefolgt.
//

import XCTest

final class TopicUpdateUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        return app
    }

    /// Auf dem iPad liegen die Tabs oben und erscheinen nicht unter `tabBars`.
    @MainActor private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Der Mini-Player erscheint, sobald etwas spielt.
    @MainActor private func miniBar(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
    }

    /// Öffnet das Blatt für ein neues Update und trägt den Namen ein.
    @MainActor private func openEditor(_ app: XCUIApplication, name: String) {
        tab(app, "Themen-Updates")
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let field = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name)
    }

    /// Wählt weitere Tags über die Suche aus, ohne ihnen zu folgen.
    @MainActor private func pickMoreTags(_ app: XCUIApplication, _ labels: [String]) {
        let more = element(app, "feed.moreTags")
        XCTAssertTrue(more.waitForExistence(timeout: 5), "„Weitere Tags“ fehlt im Blatt")
        more.tap()
        XCTAssertTrue(app.navigationBars["Weitere Tags"].waitForExistence(timeout: 5))
        for label in labels {
            let row = element(app, "tagPicker.\(label)")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Das Tag „\(label)“ steht nicht zur Auswahl")
            row.tap()
        }
        app.navigationBars["Weitere Tags"].buttons.element(boundBy: 0).tap()
        for label in labels {
            let chip = app.buttons[label].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "„\(label)“ steht nicht als Kapsel im Blatt")
            XCTAssertTrue(chip.isSelected, "„\(label)“ ist nicht ausgewählt")
        }
    }

    @MainActor private func create(_ app: XCUIApplication) {
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        XCTAssertTrue(create.isEnabled, "Anlegen bleibt gesperrt")
        create.tap()
    }

    /// „Alle zusammen“ mit Datenschutz und Sprachmodelle: der Satz darunter
    /// erklärt es, und die erste Ausgabe entsteht aus dem Kapitel, das
    /// beide Tags trägt. Kapitel 0 ist die Übersicht, und nichts spielt.
    @MainActor func testEditorWithAllTogetherBuildsEditionWithOverview() {
        let app = launchDemo()
        openEditor(app, name: "Beides zusammen")
        XCTAssertTrue(app.buttons["Datenschutz"].firstMatch.isSelected, "Das gefolgte Tag ist nicht vorausgewählt")
        pickMoreTags(app, ["Sprachmodelle"])

        let together = app.buttons["Alle zusammen"].firstMatch
        XCTAssertTrue(together.waitForExistence(timeout: 5), "Der Modus „Alle zusammen“ fehlt")
        together.tap()
        let explanation = element(app, "feed.matchMode.explanation")
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.label.contains("beides"), "Der Satz zum Modus erklärt nichts: \(explanation.label)")
        attach(app, "editor-alle-zusammen")
        create(app)

        let row = app.staticTexts["Beides zusammen"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let edition = element(app, "edition.row")
        let found = edition.waitForExistence(timeout: 90)
        attach(app, "update-alle-zusammen")
        let note = element(app, "edition.result")
        XCTAssertTrue(found, "Keine Ausgabe mit beiden Tags. Hinweis: \(note.exists ? note.label : "keiner")")
        // Eine neue Ausgabe spielt nicht von selbst.
        XCTAssertFalse(miniBar(app).exists, "Die neue Ausgabe hat von selbst Ton gestartet")

        edition.tap()
        XCTAssertTrue(element(app, "edition.overview").waitForExistence(timeout: 10),
                      "Kapitel 0, die Übersicht, fehlt")
        XCTAssertTrue(app.staticTexts["Übersicht"].firstMatch.exists)
        XCTAssertTrue(app.buttons["openOriginal"].firstMatch.waitForExistence(timeout: 5),
                      "Am Kapitel fehlt „Original öffnen“")
        attach(app, "ausgabe-uebersicht")
        XCTAssertFalse(miniBar(app).exists, "Das Öffnen der Ausgabe hat Ton gestartet")
    }

    /// Drei Kapitel mit je drei bis vier Minuten aus drei Tags: Sie kommen
    /// alle in eine Ausgabe, ohne Teile und ohne Einstellung für eine Länge.
    @MainActor func testEditionCollectsAllChaptersInOneEdition() {
        let app = launchDemo()
        openEditor(app, name: "Alles in einem")
        pickMoreTags(app, ["Automatisierung", "Haftung"])

        // Eine Länge je Teil gibt es nicht mehr, dafür den Satz zum Umfang.
        XCTAssertFalse(app.steppers.firstMatch.exists, "Das Blatt bietet noch eine Länge je Teil an")
        let scope = element(app, "feed.editionScope")
        if !scope.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "Der Satz, was in eine Ausgabe kommt, fehlt")
        attach(app, "editor-eine-ausgabe")
        create(app)

        let row = app.staticTexts["Alles in einem"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let edition = element(app, "edition.row")
        let found = edition.waitForExistence(timeout: 90)
        attach(app, "eine-ausgabe")
        let note = element(app, "edition.result")
        XCTAssertTrue(found, "Keine Ausgabe in der Liste. Hinweis: \(note.exists ? note.label : "keiner")")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "edition.row").count, 1,
            "Der Lauf steht nicht als eine Ausgabe in der Liste")
        let partLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Teil 2' OR label CONTAINS ' von 2'")).firstMatch
        XCTAssertFalse(partLabel.exists, "Die Liste nennt noch Teile: \(partLabel.exists ? partLabel.label : "")")
        XCTAssertFalse(miniBar(app).exists, "Die neue Ausgabe hat von selbst Ton gestartet")

        edition.tap()
        XCTAssertTrue(element(app, "edition.overview").waitForExistence(timeout: 10), "Kapitel 0, die Übersicht, fehlt")
        XCTAssertFalse(element(app, "edition.part").exists, "Die Ausgabe nennt einen Teil")
        // Alle drei Kapitel stehen in dieser einen Ausgabe, je eine Stelle.
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '3 Stellen'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "Die Ausgabe enthält nicht alle drei Kapitel")
        XCTAssertFalse(miniBar(app).exists, "Das Öffnen der Ausgabe hat Ton gestartet")

        // Läuft die Ausgabe, sagt der Knopf das auch (TestFlight-Feedback zu 0.13).
        let play = app.buttons["edition.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(play.label, "Abspielen")
        play.tap()
        let running = NSPredicate(format: "label == 'Pause' OR label == 'Weiter'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: running, evaluatedWith: play)], timeout: 10), .completed,
                       "Die Ausgabe spielt, der Knopf sagt weiter „\(play.label)“")
        attach(app, "ausgabe-spielt")
        if play.label == "Pause" {
            play.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == 'Weiter'"),
                                                            evaluatedWith: play)], timeout: 5), .completed,
                           "Nach „Pause“ bietet der Knopf nicht „Weiter“ an")
        }
    }
}
