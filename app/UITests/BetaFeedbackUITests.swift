//
//  BetaFeedbackUITests.swift
//  PodcastAIUITests
//
//  Die vier Rückmeldungen aus TestFlight 0.1 (1), nachgestellt mit den
//  Links aus dem Feedback.
//

import XCTest

final class BetaFeedbackUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func addSource(_ app: XCUIApplication, _ link: String) {
        app.tabBars.buttons["Meine Podcasts"].tap()
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(link)
        app.buttons["Hinzufügen"].tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPodigeeFeedURLWithoutFeedIsDiscovered() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        addSource(app, "https://think-ai.podigee.io/rssfeed")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Think'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Podigee-Podcast nicht gefunden")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach(app, "podigee")
    }

    func testDirectMP3BecomesSingleEpisode() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        addSource(app, "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=webplayer-download")
        let row = app.staticTexts["Einzelne Folgen"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "MP3 nicht als Einzelfolge angelegt")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        row.tap()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()
        // Die Folge ist spielbar. Das Transkript entsteht von selbst, deshalb
        // steht der Knopf dafür nicht mehr zwingend in der Ansicht.
        XCTAssertTrue(app.buttons["episode.play"].waitForExistence(timeout: 10))
        attach(app, "mp3")
    }

    @MainActor func testYouTubeChannelOffersAudioPodcast() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        addSource(app, "https://www.youtube.com/channel/UCDx6L69jmKBJbNu5GnkCilg")
        // Ein YouTube-Link zeigt erst die Vorschau mit den Möglichkeiten.
        let channel = app.buttons["youtube.subscribeChannel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 45), "Keine Vorschau zum YouTube-Link")
        channel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["youtube.subscribeChannel.done"].waitForExistence(timeout: 45))
        // Zurück aus der Vorschau, dann schließt „Fertig“ das Blatt.
        let back = app.navigationBars.buttons["Hinzufügen"].firstMatch
        if back.exists { back.tap() }
        let done = app.navigationBars.buttons["Fertig"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "„Fertig“ fehlt nach dem Abonnieren")
        done.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Magnussen'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let offer = app.staticTexts["Als Audio-Podcast verfügbar"].firstMatch
        let offerHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Audio-Podcast'")).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 20) || offerHeader.exists, "Kein Audio-Podcast angeboten")
        attach(app, "youtube")
    }

    func testTopicCanBeCreatedInsideTopicUpdate() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        app.tabBars.buttons["Themen-Updates"].tap()
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Neue KI Modelle")
        let topic = app.textFields["Neues Thema, z. B. KI-Modelle"]
        topic.tap(); topic.typeText("KI-Modelle")
        // Feedback zu 0.4: „Anlegen geht nicht“. Ein eingetipptes Thema
        // zählt jetzt mit, auch ohne vorher auf Hinzufügen zu tippen.
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        XCTAssertTrue(create.isEnabled, "Anlegen bleibt gesperrt")
        attach(app, "themen")
        create.tap()
        XCTAssertTrue(app.staticTexts["Neue KI Modelle"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Ein Themen-Update lässt sich öffnen, neu zusammenstellen, bearbeiten
    /// und löschen. Vorher führte es nur in seine erste Ausgabe.
    func testTopicUpdateCanBeRebuiltEditedAndDeleted() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        app.tabBars.buttons["Themen-Updates"].tap()
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Wochenupdate")
        let topic = app.textFields["Neues Thema, z. B. KI-Modelle"]
        topic.tap(); topic.typeText("Datenschutz")
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        create.tap()

        let row = app.staticTexts["Wochenupdate"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        // Solange die erste Ausgabe entsteht, heißt der Knopf anders.
        let rebuild = app.buttons["Neue Ausgabe zusammenstellen"].firstMatch
        XCTAssertTrue(rebuild.waitForExistence(timeout: 30), "Kein Knopf für eine neue Ausgabe")
        attach(app, "themen-update")

        app.navigationBars.buttons["Mehr"].firstMatch.tap()
        app.buttons["Bearbeiten"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Themen-Update bearbeiten"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Abbrechen"].firstMatch.tap()

        app.navigationBars.buttons["Mehr"].firstMatch.tap()
        app.buttons["Löschen"].firstMatch.tap()
        app.buttons["„Wochenupdate“ löschen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Noch kein Themen-Update"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Feedback zu 0.9: Nach „Anlegen“ entstand keine erste Ausgabe, erst
    /// „Neue Ausgabe zusammenstellen“ baute eine. Mit den Beispieldaten
    /// passt „Datenschutz“ auf mehrere Stellen, also muss die erste Ausgabe
    /// ohne weiteren Tipp auf der Seite des Updates stehen.
    @MainActor func testNewTopicUpdateBuildsFirstEditionWithoutTap() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh", "-demo-content"]; app.launch()
        app.tabBars.buttons["Themen-Updates"].tap()
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Erstausgabe")
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        XCTAssertTrue(create.isEnabled, "Anlegen bleibt gesperrt, obwohl Themen vorausgewählt sind")
        create.tap()

        let row = app.staticTexts["Erstausgabe"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let latest = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Neueste Ausgabe'")).firstMatch
        // Die Auswahl durch Apple Intelligence dauert auf einem ausgelasteten
        // Simulator auch einmal eine halbe Minute.
        let found = latest.waitForExistence(timeout: 90)
        attach(app, "erste-ausgabe")
        let note = app.descendants(matching: .any)["edition.result"].firstMatch
        XCTAssertTrue(found, "Keine erste Ausgabe nach dem Anlegen. Hinweis: \(note.exists ? note.label : "keiner")")
    }

    /// Derselbe Weg mit einem eingetippten Thema statt der vorhandenen.
    @MainActor func testTypedTopicUpdateBuildsFirstEditionWithoutTap() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh", "-demo-content"]; app.launch()
        app.tabBars.buttons["Themen-Updates"].tap()
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Eingetippt")
        // Die vorausgewählten Themen abwählen, damit nur das neue zählt.
        for label in ["Datenschutz", "KI im Arbeitsalltag"] {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 5) { button.tap() }
        }
        let topic = app.textFields["Neues Thema, z. B. KI-Modelle"]
        topic.tap(); topic.typeText("Automatisierung")
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        create.tap()

        let row = app.staticTexts["Eingetippt"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let latest = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Neueste Ausgabe'")).firstMatch
        // Die Auswahl durch Apple Intelligence dauert auf einem ausgelasteten
        // Simulator auch einmal eine halbe Minute.
        let found = latest.waitForExistence(timeout: 90)
        attach(app, "erste-ausgabe-eingetippt")
        let note = app.descendants(matching: .any)["edition.result"].firstMatch
        XCTAssertTrue(found, "Keine erste Ausgabe nach dem Anlegen. Hinweis: \(note.exists ? note.label : "keiner")")
    }
}
