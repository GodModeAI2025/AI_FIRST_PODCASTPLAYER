//
//  ScrollUnderLoadUITests.swift
//  PodcastAIUITests
//
//  Scrollt durch die Hauptlisten, während Apple Intelligence Fakten,
//  Kapitel-Tags und „Für dich“ rechnet. Gedacht für Messungen mit
//  Instruments (Time Profiler, Hangs, Hitches), die sich an den laufenden
//  Prozess hängen. Ohne `PODCASTAI_SCROLL_LOAD` läuft der Test nur eine
//  kurze Runde, damit die Wege der Suite abgedeckt bleiben:
//
//      TEST_RUNNER_PODCASTAI_SCROLL_LOAD=180 xcodebuild test … \
//        -only-testing:PodcastAIUITests/ScrollUnderLoadUITests
//

import XCTest

final class ScrollUnderLoadUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// Auf dem iPad liegen die Tabs oben und erscheinen nicht unter `tabBars`.
    @MainActor private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        // Nach einer Frage verdeckt die Tastatur die Tab-Leiste.
        for _ in 0..<3 where button.exists && !button.isHittable { app.swipeDown() }
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    @MainActor private func scroll(_ app: XCUIApplication, times: Int) {
        let surface = app.windows.firstMatch
        for index in 0..<times {
            if index.isMultiple(of: 2) { surface.swipeUp(velocity: .fast) } else { surface.swipeDown(velocity: .fast) }
        }
    }

    /// Stellt eine Frage im Chat und wartet auf die Antwort. Die Zeit bis zum
    /// ersten Wort steht in Instruments zwischen „Frage gestellt“ und „Erstes Token“.
    @MainActor private func ask(_ app: XCUIApplication, _ question: String) {
        tab(app, "Chat")
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        guard input.waitForExistence(timeout: 10) else { return }
        input.tap()
        // Mit dem Zeilenende abschicken: das schließt auch die Tastatur, die
        // sonst die Tab-Leiste verdeckt.
        input.typeText(question + "\n")
        let started = Date()
        let answer = app.descendants(matching: .any)["chat.answer"].firstMatch
        _ = answer.waitForExistence(timeout: 180)
        print("CHAT-ANTWORT nach \(Int(Date().timeIntervalSince(started))) s")
    }

    @MainActor func testScrollingWhileModelWorks() {
        let seconds = Double(ProcessInfo.processInfo.environment["PODCASTAI_SCROLL_LOAD"] ?? "") ?? 0
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-demo-backlog"]
        app.launch()
        // Zeit, damit sich Instruments an den Prozess hängen kann.
        if seconds > 0 { sleep(10) }
        let deadline = Date().addingTimeInterval(seconds)
        var round = 0
        repeat {
            // In der zweiten und fünften Runde eine Frage, während im Hintergrund Fakten laufen.
            if seconds > 0, round == 1 || round == 4 { ask(app, "Was sagen die Folgen über Wärmepumpen?") }
            round += 1
            // Zweimal tippen führt zurück an den Anfang des Tabs.
            tab(app, "Meine Podcasts")
            tab(app, "Meine Podcasts")
            let source = app.staticTexts["Beispiel: Energie und Klima"].firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 15), "Die Quellen fehlen")
            scroll(app, times: 4)
            source.tap()
            let episode = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Folge 1:'")).firstMatch
            if !episode.waitForExistence(timeout: 10) { print(app.debugDescription) }
            XCTAssertTrue(episode.exists, "Die Folgenliste fehlt")
            scroll(app, times: 4)
            episode.tap()
            let sections = app.segmentedControls["episode.sections"]
            XCTAssertTrue(sections.waitForExistence(timeout: 10), "Die Folge öffnet sich nicht")
            sections.buttons["Kapitel"].tap()
            scroll(app, times: 6)
            tab(app, "Für dich")
            scroll(app, times: 4)
        } while Date() < deadline
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch.exists,
                       "Scrollen hat Ton gestartet")
    }
}
