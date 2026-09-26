//
//  ConversationUITests.swift
//  PodcastAIUITests
//
//  Folgefragen im Chat einer Folge und im Chat über die Mediathek. Mit
//  `-uitest-chat-lookup` spielt ein Ersatz das Modell (nur in Debug-Builds,
//  `ChatLookupFixture`). Bei einer Folgefrage nennt seine Antwort die Frage
//  davor, so wie das Modell sie im Block BISHERIGES GESPRÄCH sähe. Daran
//  sieht der Test, dass die früheren Runden bis zum Modell kommen.
//
//  Dazu „Unterhaltung löschen“ im Reiter „Fragen“ und in der Mediathek
//  „Neue Unterhaltung“ und „Frühere Unterhaltungen“ mit Wiederöffnen und
//  Löschen. Abgespielt wird dabei nie etwas.
//

import XCTest

final class ConversationUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-uitest-chat-lookup"]
        app.launch()
        return app
    }

    @MainActor private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    @MainActor private func ask(_ app: XCUIApplication, _ question: String) {
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Das Eingabefeld fehlt")
        input.tap()
        input.typeText(question)
        app.buttons["chat.send"].tap()
    }

    @MainActor private func answers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "chat.answer")
    }

    /// Wartet, bis so viele Antworten dastehen.
    @MainActor private func waitForAnswers(_ app: XCUIApplication, count: Int, timeout: TimeInterval = 30) -> Bool {
        let predicate = NSPredicate(format: "count == %d", count)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: answers(app))
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Ein Eintrag in einem Menü, über seine Kennung oder seinen Namen.
    @MainActor private func menuItem(_ app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let byID = app.buttons[id].firstMatch
        return byID.waitForExistence(timeout: 2) ? byID : app.buttons[label].firstMatch
    }

    @MainActor private func followUpAnswer(_ app: XCUIApplication, previous: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Anschluss an „\(previous)“")).firstMatch
    }

    // MARK: - Chat einer Folge

    @MainActor func testFollowUpInEpisodeChat() {
        let app = launch()
        tab(app, "Meine Podcasts")
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()
        let sections = app.segmentedControls["episode.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        sections.buttons["Fragen"].tap()

        let first = "Was sagen sie über Daten, Teams und Regeln?"
        ask(app, first)
        XCTAssertTrue(waitForAnswers(app, count: 1), "Die erste Antwort fehlt")

        ask(app, "Und was sagen sie dazu noch?")
        XCTAssertTrue(waitForAnswers(app, count: 2), "Die Folgefrage bekommt keine Antwort")
        XCTAssertTrue(followUpAnswer(app, previous: first).waitForExistence(timeout: 5),
                      "Die Folgefrage kam ohne die Frage davor beim Modell an")
        XCTAssertFalse(app.buttons["Pause"].exists, "Eine Folgefrage hat Ton gestartet")
        attach(app, "folge-folgefrage")

        // „Unterhaltung löschen“ leert den Chat der Folge.
        let menu = app.descendants(matching: .any)["chat.conversationMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Im Reiter Fragen fehlt das Menü der Unterhaltung")
        menu.tap()
        let delete = menuItem(app, id: "chat.deleteConversation", label: "Unterhaltung löschen")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Im Menü fehlt „Unterhaltung löschen“")
        delete.tap()
        let confirm = menuItem(app, id: "chat.confirmDeleteConversation", label: "Löschen")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Die Rückfrage vor dem Löschen fehlt")
        confirm.tap()
        XCTAssertTrue(waitForAnswers(app, count: 0, timeout: 5), "Nach dem Löschen stehen noch Antworten da")
        XCTAssertTrue(app.staticTexts["Frag diese Folge"].waitForExistence(timeout: 5),
                      "Nach dem Löschen fehlt der leere Chat der Folge")
        attach(app, "folge-unterhaltung-geloescht")
    }

    // MARK: - Chat über die Mediathek

    @MainActor func testFollowUpAndConversationsInLibraryChat() {
        let app = launch()
        tab(app, "Chat")

        let first = "Was sagen sie über Daten, Teams und Regeln?"
        ask(app, first)
        XCTAssertTrue(waitForAnswers(app, count: 1), "Die erste Antwort fehlt")
        ask(app, "Und was sagen sie dazu noch?")
        XCTAssertTrue(waitForAnswers(app, count: 2), "Die Folgefrage bekommt keine Antwort")
        XCTAssertTrue(followUpAnswer(app, previous: first).waitForExistence(timeout: 5),
                      "Die Folgefrage kam ohne die Frage davor beim Modell an")
        attach(app, "mediathek-folgefrage")

        // „Neue Unterhaltung“ beginnt leer.
        let menu = app.descendants(matching: .any)["chat.conversationMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Oben fehlt das Menü der Unterhaltung")
        menu.tap()
        let fresh = menuItem(app, id: "chat.newConversation", label: "Neue Unterhaltung")
        XCTAssertTrue(fresh.waitForExistence(timeout: 5), "Im Menü fehlt „Neue Unterhaltung“")
        fresh.tap()
        XCTAssertTrue(waitForAnswers(app, count: 0, timeout: 5), "Die neue Unterhaltung zeigt alte Antworten")

        // Die bisherige steht unter „Frühere Unterhaltungen“ und kommt mit
        // beiden Antworten zurück.
        menu.tap()
        let list = menuItem(app, id: "chat.conversationList", label: "Frühere Unterhaltungen")
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Im Menü fehlt „Frühere Unterhaltungen“")
        list.tap()
        let row = app.descendants(matching: .any).matching(identifier: "chat.conversationRow")
            .matching(NSPredicate(format: "label CONTAINS %@", first)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Die bisherige Unterhaltung fehlt in der Liste")
        attach(app, "mediathek-fruehere-unterhaltungen")
        row.tap()
        XCTAssertTrue(waitForAnswers(app, count: 2, timeout: 10), "Die wieder geöffnete Unterhaltung ist unvollständig")

        // Eine weitere Folgefrage geht in derselben Unterhaltung weiter.
        let second = "Und was sagen sie dazu noch?"
        ask(app, "Welche Stelle ist die wichtigste?")
        XCTAssertTrue(waitForAnswers(app, count: 3), "Nach dem Wiederöffnen geht die Unterhaltung nicht weiter")
        XCTAssertTrue(followUpAnswer(app, previous: second).waitForExistence(timeout: 5),
                      "Nach dem Wiederöffnen fehlt der Verlauf beim Modell")

        // Löschen per Wischen in der Liste.
        menu.tap()
        list.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let delete = app.buttons["Löschen"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Wischen bietet „Löschen“ nicht an")
        delete.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2), "Die gelöschte Unterhaltung steht noch in der Liste")
        app.buttons["chat.conversationListDone"].firstMatch.tap()
        XCTAssertTrue(waitForAnswers(app, count: 0, timeout: 5), "Die gelöschte Unterhaltung steht noch im Chat")
        XCTAssertFalse(app.buttons["Pause"].exists, "Der Chat hat Ton gestartet")
        attach(app, "mediathek-unterhaltung-geloescht")
    }
}
