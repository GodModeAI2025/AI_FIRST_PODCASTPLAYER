//
//  AtlasUITests.swift
//  PodcastAIUITests
//
//  Fotografiert alle wichtigen Bildschirme mit Beispielinhalten. Der Atlas
//  dient dem Persona-Test und der Durchsicht der Oberfläche. Läuft nur mit
//  RUN_ATLAS=1, damit der normale Testlauf schnell bleibt.
//

import XCTest

final class AtlasUITests: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private func snap(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "atlas-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "atlas-\(name)-baum"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 5) {
        if element.waitForExistence(timeout: timeout) { element.tap() }
    }

    func testCaptureAtlas() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_ATLAS"] == "1"
                          || ProcessInfo.processInfo.environment["RUN_ATLAS"] == "1")

        // Einführung beim ersten Start
        let intro = XCUIApplication()
        intro.launchArguments = ["-uitest-fresh", "-show-onboarding"]
        intro.launch()
        snap(intro, "00-einfuehrung")
        intro.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        sleep(3)
        snap(app, "01-fuer-dich")

        app.tabBars.buttons["Themen"].tap()
        snap(app, "02-meine-feeds")
        tapIfExists(app.navigationBars.buttons["Neu"].firstMatch)
        snap(app, "03-themen-update-anlegen")
        tapIfExists(app.buttons["Abbrechen"].firstMatch)

        app.tabBars.buttons["Fragen"].firstMatch.tap()
        snap(app, "04-fragen")
        tapIfExists(app.buttons["Welche Folgen behandeln künstliche Intelligenz?"])
        sleep(4)
        snap(app, "05-fragen-antwort")

        app.tabBars.buttons["Mediathek"].tap()
        snap(app, "06-mediathek")
        tapIfExists(app.staticTexts["Warteschlange"].firstMatch)
        snap(app, "07-warteschlange")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tapIfExists(app.staticTexts["Beispiel: Arbeit und KI"].firstMatch)
        snap(app, "08-folgenliste")
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        tapIfExists(episode)
        snap(app, "09-folge-ueberblick")
        app.swipeUp()
        snap(app, "09b-folge-ueberblick-unten")
        let sections = app.segmentedControls["episode.sections"]
        for (name, file) in [("Kapitel", "10-folge-kapitel"), ("Transkript", "11-folge-transkript"),
                             ("Fakten", "12-folge-fakten"), ("Fragen", "13-folge-fragen")] {
            if sections.waitForExistence(timeout: 5) { sections.buttons[name].tap() }
            snap(app, file)
        }
        tapIfExists(app.buttons["Worum geht es in dieser Folge?"])
        sleep(4)
        snap(app, "14-folge-antwort")
        sections.buttons["Überblick"].tap()
        tapIfExists(app.buttons["episode.menu"])
        snap(app, "15-folge-menue")
        app.tap()
        tapIfExists(app.buttons["episode.play"])
        sleep(3)
        let miniBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
        tapIfExists(miniBar)
        snap(app, "16-player")
        tapIfExists(app.buttons["Fertig"].firstMatch)

        app.tabBars.buttons["Mediathek"].tap()
        app.tabBars.buttons["Mediathek"].tap()
        tapIfExists(app.navigationBars.buttons["Quelle hinzufügen"].firstMatch)
        snap(app, "17-quelle-hinzufuegen")
        tapIfExists(app.buttons["Abbrechen"].firstMatch)

        app.tabBars.buttons["Wissen"].tap()
        snap(app, "18-wissen")
        for (label, file) in [("Gemerkte Stellen", "19-gemerkte-stellen"), ("Wissenslandkarten", "20-wissenslandkarten"),
                              ("Gegenpositionen", "21-gegenpositionen"), ("Interessen", "22-interessen"),
                              ("Einstellungen", "23-einstellungen"), ("So funktioniert", "24-hilfe")] {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if row.waitForExistence(timeout: 5) {
                row.tap()
                snap(app, file)
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
        }
        app.tabBars.buttons["Für dich"].tap()
        snap(app, "25-fuer-dich-spaeter")
    }
}
