//
//  MacWindowUITests.swift
//  PodcastAIMacUITests
//
//  Die Hauptwege der Mac-App: Bereiche über ⌘1 bis ⌘7, der Inspektor über
//  ⌥⌘U, die Hilfe über das Menü. Dazu Regel 1: Öffnen spielt nichts, und
//  ohne geladene Folge ist Abspielen in der Symbolleiste gesperrt.
//

import XCTest

@MainActor
final class MacWindowUITests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(demo: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-skip-onboarding", "-AppleLanguages", "(de)"]
        if demo { app.launchArguments.append("-demo-content") }
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Kein Fenster")
        return app
    }

    /// Wartet, bis das vordere Fenster den Titel trägt.
    private func waitForTitle(_ title: String, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        let predicate = NSPredicate(format: "title == %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: window)
        let result = XCTWaiter().wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Fenstertitel ist nicht „\(title)“", file: file, line: line)
    }

    func testCommandNumbersSwitchSections() {
        let app = launch()
        // Der Chat heißt in der Seitenleiste „Chat“, sein Fenstertitel ist
        // „Frag deine Podcasts“.
        let titles = ["Für dich", "Themen-Updates", "Meine Podcasts", "Frag deine Podcasts",
                      "Gemerkte Stellen", "Gesicherte Antworten", "Meine Tags"]
        for (index, title) in titles.enumerated() {
            app.typeKey("\(index + 1)", modifierFlags: .command)
            waitForTitle(title, in: app)
        }
    }

    func testToolbarPlayIsDisabledWhenIdle() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["nowPlaying.idle"].waitForExistence(timeout: 10),
                      "Die Anzeige sagt nicht, dass nichts läuft")
        let play = app.buttons["toolbar.playPause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertFalse(play.isEnabled, "Abspielen ist ohne geladene Folge bedienbar")
    }

    func testInspectorToggleShowsUpNext() {
        let app = launch()
        app.typeKey("u", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["Nichts als Nächstes"].waitForExistence(timeout: 5),
                      "⌥⌘U zeigt „Als Nächstes“ nicht")
    }

    func testHelpMenuOpensHelp() {
        let app = launch()
        app.menuBars.menuBarItems["Hilfe"].click()
        app.menuItems["PodcastAI-Hilfe"].click()
        waitForTitle("So funktioniert's", in: app)
    }

    /// Eine Folge auswählen und mit Return öffnen spielt nichts. Die Anzeige
    /// bleibt bei „Nichts wird abgespielt“.
    func testReturnOpensEpisodeWithoutPlaying() throws {
        let app = launch(demo: true, extra: ["-uitest-sidebar", "firstPodcast"])
        let table = app.tables.firstMatch
        guard table.waitForExistence(timeout: 15) else {
            throw XCTSkip("Keine Demo-Inhalte geladen")
        }
        let row = table.tableRows.element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Die Tabelle hat keine Folge")
        row.click()
        XCTAssertTrue(app.staticTexts["nowPlaying.idle"].exists, "Auswählen hat Ton gestartet")
        row.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["episode.sections"].firstMatch.waitForExistence(timeout: 10),
                      "Return hat die Folge nicht geöffnet")
        XCTAssertTrue(app.staticTexts["nowPlaying.idle"].exists, "Öffnen hat Ton gestartet")
    }
}
