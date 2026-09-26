//
//  ChatLookupUITests.swift
//  PodcastAIUITests
//
//  Der Chat schlägt selbst nach. Mit `-uitest-chat-lookup` spielt ein
//  Ersatz das Modell (nur in Debug-Builds, `ChatLookupFixture`): Er sieht
//  zwei Abschnitte der Beispielfolge und holt sich über das Werkzeug für
//  weitere Stellen eine dazu. Buch, Quelle und Zuordnung der Belege sind die
//  echten. Geprüft wird, dass die ruhige Zeile „Sucht weitere Stellen …“
//  erscheint, solange das Werkzeug läuft, dass die Antwort danach die
//  nachgeschlagene Stelle als Beleg zeigt und dass dabei kein Ton entsteht.
//

import XCTest

final class ChatLookupUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testLookupStatusAndDeliveredCitation() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-uitest-chat-lookup"]
        app.launch()
        app.tabBars.buttons["Chat"].firstMatch.tap()

        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Das Eingabefeld fehlt")
        input.tap()
        // Die Stichworte treffen vier der acht Stellen der Beispielfolge. Der
        // Ersatz sieht zwei davon, das Werkzeug findet die übrigen, auch ohne
        // Satzeinbettungen im Simulator.
        input.typeText("Was sagen sie über Daten, Teams und Regeln?")
        app.buttons["chat.send"].tap()

        // Solange das Werkzeug läuft, steht die Zeile auf der Karte der Frage.
        let status = app.descendants(matching: .any)["chat.lookupStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20), "Die Zeile zum Nachschlagen erscheint nicht")
        XCTAssertTrue(status.label.contains("Sucht weitere Stellen"), "Unerwartete Zeile: \(status.label)")
        attach(app, "chat-nachschlagen")

        // Danach steht die Antwort da, mit der nachgeschlagenen Stelle als Beleg.
        let answer = app.descendants(matching: .any)["chat.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20), "Nach dem Nachschlagen fehlt die Antwort")
        XCTAssertFalse(status.exists, "Die Zeile zum Nachschlagen bleibt nach der Antwort stehen")
        XCTAssertTrue(answer.staticTexts["Belege"].waitForExistence(timeout: 5),
                      "Die Antwort zeigt die nachgeschlagene Stelle nicht als Beleg")
        // Nur diese Fassung verweist auf eine Stelle, die das Werkzeug geliefert
        // hat. Die andere verweist auf einen der beiden ersten Abschnitte.
        let text = answer.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Eine weitere Stelle sagt dazu mehr")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5),
                      "Die Antwort verweist nicht auf eine nachgeschlagene Stelle")
        XCTAssertFalse(text.label.contains("F1"), "Eine Kennung der Werkzeuge steht in der Antwort")
        // Abgespielt wird dabei nichts.
        XCTAssertFalse(app.buttons["Pause"].exists, "Das Nachschlagen hat Ton gestartet")
        attach(app, "chat-nachgeschlagen")
    }
}
