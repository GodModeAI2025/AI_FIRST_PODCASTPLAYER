//
//  ChapterPageUITests.swift
//  PodcastAIUITests
//
//  Die Folge nach Kapiteln: je Kapitel Fakten und ein Stück Transkript,
//  ohne dass Ton startet. Aus einem Themen-Update führt „Original öffnen“
//  in die Folge, aus der ein Kapitel stammt.
//

import XCTest

final class ChapterPageUITests: XCTestCase {

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

    @MainActor func testChaptersShowFactsAndTranscript() {
        let app = launchDemo()
        tab(app, "Meine Podcasts")
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()

        let sections = app.segmentedControls["episode.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        sections.buttons["Kapitel"].tap()

        // Das Kapitel aus dem Feed und darunter die Aussage, die in ihm liegt.
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Datenschutz und Modelle'")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), "Das Kapitel fehlt")
        let fact = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Modelle auf dem Gerät verarbeiten'")).firstMatch
        XCTAssertTrue(fact.waitForExistence(timeout: 10), "Die Aussage steht nicht unter ihrem Kapitel")
        XCTAssertGreaterThan(fact.frame.minY, chapter.frame.minY, "Die Aussage steht über ihrem Kapitel")
        let excerpt = app.descendants(matching: .any)["chapter.excerpt"].firstMatch
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5), "Kein Transkript im Kapitel")
        attach(app, "kapitel-mit-fakten")

        // Öffnen und Lesen starten keinen Ton.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch.exists,
                       "Der Reiter Kapitel hat Ton gestartet")
    }

    /// Ein Kapitel eines Themen-Updates öffnet seine Originalfolge, auf Tippen.
    @MainActor func testTopicUpdateChapterOpensOriginal() throws {
        let app = launchDemo()
        tab(app, "Themen-Updates")
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Datenschutz kompakt")
        // Das gefolgte Tag Datenschutz der Beispielfolge ist vorausgewählt.
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        create.tap()

        let row = app.staticTexts["Datenschutz kompakt"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let chapters = app.buttons["Kapitel und Quellen"].firstMatch
        guard chapters.waitForExistence(timeout: 30) else {
            throw XCTSkip("Aus den Beispieldaten ist keine Ausgabe entstanden")
        }
        chapters.tap()

        let open = app.buttons["openOriginal"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Am Kapitel fehlt „Original öffnen“")
        // Vor dem Tipp läuft nichts.
        let miniBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
        XCTAssertFalse(miniBar.exists, "Das Themen-Update hat von selbst Ton gestartet")
        attach(app, "ausgabe-original")
        open.tap()
        XCTAssertTrue(miniBar.waitForExistence(timeout: 10), "„Original öffnen“ hat die Folge nicht geöffnet")
    }
}
