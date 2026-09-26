//
//  ChatNarrowingUITests.swift
//  PodcastAIUITests
//
//  Eingrenzung im Eingabefeld des Chats: „Podcast: …“ und „seit 1. Juni“
//  werden über Vorschläge zu Tokens über dem Feld, ein Tipp auf ein Token
//  nimmt es heraus. Danach die letzten Fragen: ein Tipp setzt die Frage
//  ins Feld und sendet sie nicht. Die Frage nach Links beantworten die
//  erkannten Nennungen der Beispielfolge, ohne Apple Intelligence.
//

import XCTest

final class ChatNarrowingUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testTokensAndRecentQuestions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        app.tabBars.buttons["Chat"].firstMatch.tap()

        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Das Eingabefeld fehlt")
        input.tap()

        // „Podcast:“ schlägt die Abos vor, der Tipp setzt das Token.
        input.typeText("Podcast: Beispiel")
        let suggestion = app.buttons["chat.tokenSuggestion"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Kein Vorschlag für den Podcast")
        XCTAssertTrue(suggestion.label.contains("Beispiel: Arbeit und KI"), "Vorschlag: \(suggestion.label)")
        suggestion.tap()
        let tokens = app.buttons.matching(identifier: "chat.token")
        XCTAssertTrue(tokens.firstMatch.waitForExistence(timeout: 5), "Über dem Feld steht kein Token")
        XCTAssertTrue(tokens.firstMatch.label.contains("Beispiel: Arbeit und KI"), "Token: \(tokens.firstMatch.label)")
        let scope = app.descendants(matching: .any)["chat.scope"].firstMatch
        XCTAssertTrue(scope.label.contains("Beispiel: Arbeit und KI"), "Der Bereich nennt den Podcast nicht: \(scope.label)")
        XCTAssertFalse(app.buttons["chat.cancel"].exists, "Ein Vorschlag hat eine Frage gesendet")

        // Eine Zeitangabe wird zum zweiten Token, ein Tipp nimmt es wieder heraus.
        input.typeText("seit 1. Juni")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Kein Vorschlag für die Zeitangabe")
        suggestion.tap()
        XCTAssertTrue(tokens.element(boundBy: 1).waitForExistence(timeout: 5), "Die Zeitangabe steht nicht als Token da")
        attach(app, "chat-tokens")
        tokens.element(boundBy: 1).tap()
        XCTAssertTrue(tokens.element(boundBy: 1).waitForNonExistence(timeout: 5), "Das angetippte Token steht noch da")
        XCTAssertEqual(tokens.count, 1, "Mit der Zeitangabe ist auch der Podcast verschwunden")

        // Gefragt wird im eingegrenzten Bereich.
        input.tap()
        input.typeText("Welche Links werden genannt?")
        app.buttons["chat.send"].tap()
        let answers = app.descendants(matching: .any).matching(identifier: "chat.answer")
        XCTAssertTrue(answers.firstMatch.waitForExistence(timeout: 20), "Keine Antwort im eingegrenzten Bereich")
        let answered = answers.count

        // Leeres Feld mit Cursor: die letzten Fragen. Ein Tipp füllt nur das Feld.
        input.tap()
        let recent = app.buttons["chat.recent"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "Die letzten Fragen fehlen")
        XCTAssertTrue(recent.label.contains("Welche Links werden genannt?"), "Letzte Frage: \(recent.label)")
        attach(app, "chat-letzte-fragen")
        recent.tap()
        XCTAssertTrue((input.value as? String)?.contains("Welche Links werden genannt?") == true,
                      "Die Frage steht nicht im Feld")
        XCTAssertFalse(app.buttons["chat.cancel"].waitForExistence(timeout: 2), "Die letzte Frage wurde gesendet")
        XCTAssertEqual(answers.count, answered, "Eine letzte Frage hat eine neue Antwort ausgelöst")
        XCTAssertTrue(app.buttons["chat.send"].isEnabled, "Senden bleibt gesperrt, obwohl eine Frage im Feld steht")
        // Abgespielt wird dabei nichts.
        XCTAssertFalse(app.buttons["Pause"].exists, "Tokens oder letzte Fragen haben Ton gestartet")
    }
}
