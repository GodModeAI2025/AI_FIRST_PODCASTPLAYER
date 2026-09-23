//
//  MentionsUITests.swift
//  PodcastAIUITests
//
//  „Erwähnt“ in der Beispielfolge: der Abschnitt im Überblick, die Liste
//  dahinter mit Link, Termin und Adresse, und die Frage nach Links im Chat
//  der Folge. Die Antwort kommt aus den erkannten Nennungen und braucht
//  deshalb kein Apple Intelligence, auch nicht im Simulator.
//

import XCTest

final class MentionsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    func testMentionsInOverviewAndEpisodeChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        tab(app, "Meine Podcasts")
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()

        // Im Überblick, unter „Kurz gesagt“.
        let mentions = app.descendants(matching: .any)["episode.mentions"].firstMatch
        for _ in 0..<6 where !mentions.exists { app.swipeUp() }
        XCTAssertTrue(mentions.waitForExistence(timeout: 10), "Im Überblick fehlt „Erwähnt“")
        XCTAssertTrue(mentions.label.contains("Link"), "Die Zusammenfassung nennt keine Links")
        attach(app, "erwaehnt-ueberblick")

        mentions.tap()
        let spoken = app.staticTexts["example.org/workshop"].firstMatch
        XCTAssertTrue(spoken.waitForExistence(timeout: 10), "Der gesprochene Link fehlt in der Liste")
        XCTAssertTrue(app.staticTexts["example.org/ki-arbeit"].firstMatch.exists, "Der Link aus den Shownotes fehlt")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Musterstraße 12'")).firstMatch.exists,
                      "Die Adresse fehlt")
        XCTAssertTrue(app.buttons["In den Kalender"].firstMatch.exists, "Beim Termin fehlt „In den Kalender“")
        XCTAssertTrue(app.buttons["mention.occurrence"].firstMatch.exists, "Keine Stelle mit Zeitmarke")
        attach(app, "erwaehnt-liste")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Die Frage im Chat der Folge.
        let sections = app.segmentedControls["episode.sections"]
        for _ in 0..<6 where !sections.isHittable { app.swipeDown() }
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        sections.buttons["Fragen"].tap()
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Im Reiter Fragen fehlt das Eingabefeld")
        input.tap()
        input.typeText("Welche Links werden genannt?")
        app.buttons["chat.send"].tap()
        // Die Antwort steht in Punkten, jeder Link in seiner eigenen Zeile.
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'example.org/workshop'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20), "Die Antwort nennt den Link nicht")
        attach(app, "erwaehnt-chat")
        let shownotesLink = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'example.org/ki-arbeit'")).firstMatch
        XCTAssertTrue(shownotesLink.exists, "Die Antwort nennt den Link aus den Shownotes nicht")
    }
}
