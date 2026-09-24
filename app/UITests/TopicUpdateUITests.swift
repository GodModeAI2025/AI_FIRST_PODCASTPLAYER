//
//  TopicUpdateUITests.swift
//  PodcastAIUITests
//
//  Themen-Updates seit 0.11: Tags als Kapseln, „alle zusammen“, Ausgaben in
//  Teilen wie Folgen, die Übersicht als Kapitel 0 und kein Ton ohne Tipp.
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

    /// Drei Kapitel mit je drei bis vier Minuten und Teile zu fünf Minuten:
    /// Die Ausgaben stehen wie Folgen da, mit „Teil 2 von …“.
    @MainActor func testEditionsListShowsParts() {
        let app = launchDemo()
        openEditor(app, name: "In Teilen")
        pickMoreTags(app, ["Automatisierung", "Haftung"])

        // Von 20 auf 5 Minuten je Teil.
        let stepper = app.steppers.firstMatch
        if !stepper.isHittable { app.swipeUp() }
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "Die Länge je Teil fehlt")
        let decrement = stepper.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Verringern' OR label CONTAINS[c] 'Decrement' OR identifier CONTAINS[c] 'Decrement'"
        )).firstMatch
        for _ in 0..<3 { decrement.tap() }
        XCTAssertTrue(app.staticTexts["5 Minuten je Teil"].firstMatch.waitForExistence(timeout: 5),
                      "Die Länge je Teil steht nicht auf 5 Minuten")
        attach(app, "editor-teile")
        create(app)

        let row = app.staticTexts["In Teilen"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let second = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Teil 2 von'")).firstMatch
        let found = second.waitForExistence(timeout: 90)
        attach(app, "ausgaben-in-teilen")
        let note = element(app, "edition.result")
        XCTAssertTrue(found, "Kein Teil 2 in der Liste. Hinweis: \(note.exists ? note.label : "keiner")")
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any).matching(identifier: "edition.row").count, 2,
            "Die Teile stehen nicht einzeln in der Liste")
        XCTAssertFalse(miniBar(app).exists, "Die neuen Teile haben von selbst Ton gestartet")

        second.tap()
        XCTAssertTrue(element(app, "edition.part").waitForExistence(timeout: 10), "Die Ausgabe nennt ihren Teil nicht")
        XCTAssertTrue(element(app, "edition.overview").exists, "Kapitel 0, die Übersicht, fehlt")
        XCTAssertFalse(miniBar(app).exists, "Das Öffnen eines Teils hat Ton gestartet")
    }
}
