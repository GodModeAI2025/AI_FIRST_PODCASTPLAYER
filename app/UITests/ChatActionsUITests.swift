//
//  ChatActionsUITests.swift
//  PodcastAIUITests
//
//  Die Aktionen unter einer Antwort im Chat über die Mediathek: das Menü
//  mit „Aus dem Verlauf entfernen“ und „Mehr aus dieser Folge“ auf der
//  Karte einer zitierten Folge. Die Frage nach Links beantworten die
//  erkannten Nennungen der Beispielfolge, ohne Apple Intelligence.
//

import XCTest

final class ChatActionsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func ask(_ app: XCUIApplication, _ question: String) {
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Das Eingabefeld fehlt")
        input.tap()
        input.typeText(question)
        app.buttons["chat.send"].tap()
    }

    @MainActor func testActionsUnderAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        app.tabBars.buttons["Chat"].firstMatch.tap()

        ask(app, "Welche Links werden genannt?")
        let more = app.buttons["chat.moreFromEpisode"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), "Unter der Antwort fehlt „Mehr aus dieser Folge“")
        attach(app, "chat-aktionen")

        // Entfernen nimmt die Antwort aus dem Verlauf.
        app.buttons["chat.answerMenu"].firstMatch.tap()
        // Kennungen erreichen Einträge eines Menüs nicht immer, dann zählt der Name.
        let byID = app.buttons["chat.removeAnswer"].firstMatch
        let byLabel = app.buttons["Aus dem Verlauf entfernen"].firstMatch
        let remove = byID.waitForExistence(timeout: 2) ? byID : byLabel
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Im Menü der Antwort fehlt „Aus dem Verlauf entfernen“")
        remove.tap()
        XCTAssertFalse(more.waitForExistence(timeout: 2), "Die entfernte Antwort steht noch da")

        // „Mehr aus dieser Folge“ stellt die nächsten Fragen an die Folge.
        ask(app, "Welche Links werden genannt?")
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let scope = app.descendants(matching: .any)["chat.scope"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertTrue(scope.label.contains("Folge:"), "Der Bereich ist nicht die Folge: \(scope.label)")
        XCTAssertTrue(app.staticTexts["Frag diese Folge"].waitForExistence(timeout: 5),
                      "Nach dem Wechsel fehlt der leere Chat der Folge")
        // Abgespielt wird dabei nichts.
        XCTAssertFalse(app.buttons["Pause"].exists, "Eine Aktion unter der Antwort hat Ton gestartet")
        attach(app, "chat-mehr-aus-folge")
    }
}
