//
//  PersonaFlowsUITests.swift
//  PodcastAIUITests
//
//  Wege, an denen Testpersonen gescheitert sind: einen Podcast über seinen
//  Namen finden und beim Hören einen Moment mit Kommentar merken.
//

import XCTest

final class PersonaFlowsUITests: XCTestCase {

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

    /// Wer nur den Namen kennt, findet den Podcast und abonniert ihn im Blatt.
    func testSubscribeByName() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        tab(app, "Meine Podcasts")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("AI to the DNA")
        let subscribe = app.buttons.matching(NSPredicate(format: "label ENDSWITH ' abonnieren'")).firstMatch
        XCTAssertTrue(subscribe.waitForExistence(timeout: 20), "Keine Treffer zur Suche nach Namen")
        attach(app, "suche-treffer")
        subscribe.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Abonniert'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "Keine Bestätigung nach dem Abonnieren")
        attach(app, "suche-abonniert")
        app.buttons["Fertig"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["AI to the DNA"].firstMatch.waitForExistence(timeout: 10),
                      "Der abonnierte Podcast fehlt unter Meine Podcasts")
    }

    /// Spotify-Links bekommen einen Grund und das Blatt bleibt offen.
    func testSpotifyLinkExplainsItself() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        tab(app, "Meine Podcasts")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://open.spotify.com/show/2MAi0BvDc6GTFvKFPXnkCL")
        app.buttons["source.addLink"].tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Spotify gibt keine'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), "Kein Hinweis zum Spotify-Link")
        XCTAssertTrue(field.exists, "Das Blatt hat sich trotz Fehler geschlossen")
    }

    /// Im Player einen Moment merken, mit Kommentar, und ihn unter Wissen wiederfinden.
    func testNoteAtPlaybackPosition() {
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
        let play = app.buttons["episode.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let miniBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 10))
        miniBar.tap()
        let note = app.buttons["player.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "Im Player fehlt „Moment merken“")
        note.tap()
        let text = app.descendants(matching: .any)["note.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Wichtig für unser Team")
        attach(app, "notiz-blatt")
        app.buttons["note.save"].tap()
        // Nach „Merken“ sagt der Player kurz, bei welcher Zeit und wo die Notiz liegt.
        let confirmation = app.descendants(matching: .any)["confirmation"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "Keine Bestätigung nach „Merken“")
        app.buttons["Fertig"].firstMatch.tap()

        // In der Folge unter „Deine Notizen“, weiter unten im Überblick.
        let inEpisode = app.staticTexts["Wichtig für unser Team"].firstMatch
        for _ in 0..<5 where !inEpisode.exists { app.swipeUp() }
        XCTAssertTrue(inEpisode.waitForExistence(timeout: 5), "Die Notiz fehlt im Überblick der Folge")
        attach(app, "notiz-in-folge")
        // Beim Scrollen verkleinert sich die Tab-Leiste.
        for _ in 0..<5 where !app.tabBars.buttons["Wissen"].isHittable { app.swipeDown() }
        tab(app, "Wissen")
        app.staticTexts["Gemerkte Stellen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Wichtig für unser Team"].firstMatch.waitForExistence(timeout: 5),
                      "Die Notiz fehlt unter Gemerkte Stellen")
        attach(app, "gemerkte-stellen")
    }
}
