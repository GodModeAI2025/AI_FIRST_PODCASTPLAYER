//
//  BetaFeedback03UITests.swift
//  PodcastAIUITests
//
//  Die Rückmeldungen aus TestFlight 0.2, nachgestellt mit den Links aus dem
//  Feedback.
//

import XCTest

final class BetaFeedback03UITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func addSource(_ app: XCUIApplication, _ link: String) {
        app.tabBars.buttons["Mediathek"].tap()
        app.navigationBars.buttons["Quelle hinzufügen"].firstMatch.tap()
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

    /// „Feed abonnieren geht nicht“: feeds.transistor.fm/ai-to-the-dna.
    /// Danach eine Folge öffnen, abspielen und den Player sehen.
    func testTransistorFeedEpisodeDetailAndPlayback() {
        let app = XCUIApplication(); app.launchArguments = ["-skip-onboarding"]; app.launch()
        let row = app.staticTexts["AI to the DNA"].firstMatch
        app.tabBars.buttons["Mediathek"].tap()
        if !row.waitForExistence(timeout: 3) {
            addSource(app, "https://feeds.transistor.fm/ai-to-the-dna")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Transistor-Feed wurde nicht abonniert")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        row.tap()

        let firstEpisode = app.cells.element(boundBy: 1)
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 15))
        firstEpisode.tap()

        let play = app.buttons["episode.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Kein Abspielen-Knopf in der Folge")
        attach(app, "folge")
        play.tap()
        // Kapitel stehen im eigenen Reiter, geladen aus der Kapiteldatei des Feeds.
        let sections = app.segmentedControls["episode.sections"]
        sections.buttons["Kapitel"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Intro'")).firstMatch
                        .waitForExistence(timeout: 40), "Keine Kapitel")
        attach(app, "kapitel")
        sections.buttons["Überblick"].tap()
        let shownotes = app.staticTexts["Shownotes"].firstMatch
        for _ in 0..<40 where !shownotes.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(shownotes.exists, "Keine Shownotes")
        attach(app, "shownotes")

        let miniBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 10), "Kein Mini-Player für die Folge")
        miniBar.tap()
        XCTAssertTrue(app.navigationBars["Jetzt läuft"].waitForExistence(timeout: 5))
        attach(app, "player")
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Fertig"].firstMatch.tap()
    }

    /// „Es braucht einen zentralen Platz für Wartelisten“.
    func testQueueIsReachableFromLibrary() {
        let app = XCUIApplication(); app.launchArguments = ["-skip-onboarding"]; app.launch()
        app.tabBars.buttons["Mediathek"].tap()
        let queue = app.staticTexts["Warteschlange"].firstMatch
        if !queue.waitForExistence(timeout: 3) {
            addSource(app, "https://feeds.transistor.fm/ai-to-the-dna")
        }
        XCTAssertTrue(queue.waitForExistence(timeout: 30))
        queue.tap()
        XCTAssertTrue(app.staticTexts["Als Nächstes hören"].firstMatch.waitForExistence(timeout: 5)
                      || app.staticTexts["ALS NÄCHSTES HÖREN"].firstMatch.exists)
        attach(app, "warteschlange")
    }

    /// Aus 0.1 offen geblieben: „Die Unterscheidung muss erklärt werden“.
    func testInterestKindsAreExplained() {
        let app = XCUIApplication(); app.launchArguments = ["-skip-onboarding"]; app.launch()
        app.tabBars.buttons["Wissen"].tap()
        let interests = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Interessen'")).firstMatch
        XCTAssertTrue(interests.waitForExistence(timeout: 5))
        interests.tap()
        let explanation = app.staticTexts["interest.kind.explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.label.contains("dauerhaft"))
        attach(app, "interessen")
    }

    /// Feedback zu 0.3: „Anzeige springt, es kommt auch kein Audio“. Das
    /// passierte bei Folgen, die schon geladen waren: die lokale Datei hat
    /// keine Endung, und AVFoundation konnte sie nicht öffnen.
    func testDownloadedEpisodeActuallyPlays() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        addSource(app, "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=webplayer-download")
        let row = app.staticTexts["Einzelne Folgen"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()

        // Die App bereitet neue Folgen von selbst vor und lädt die Datei
        // dabei. Im Simulator scheitert danach die Transkription, die Datei
        // bleibt aber liegen. Genau dieser Zustand machte die Wiedergabe stumm.
        let analyze = app.buttons["Erschliessen"].firstMatch
        if analyze.waitForExistence(timeout: 5) { analyze.tap() }
        let loaded = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'fehlgeschlagen' OR label BEGINSWITH 'transkribiert' OR label BEGINSWITH 'erschlossen' OR label BEGINSWITH 'geladen'")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 300), "Folge wurde nicht geladen")
        attach(app, "geladen")

        app.buttons["episode.play"].tap()
        let miniBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 10))
        miniBar.tap()
        XCTAssertTrue(app.navigationBars["Jetzt läuft"].waitForExistence(timeout: 5))
        // Die Folge kann an einer gemerkten Stelle fortsetzen. Geprüft wird
        // deshalb nicht eine feste Zeit, sondern dass die Zeit weiterläuft.
        let elapsed = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9]{2}(:[0-9]{2})?$'")).firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        sleep(3)
        let first = Self.seconds(elapsed.label)
        sleep(5)
        let second = Self.seconds(elapsed.label)
        XCTAssertFalse(app.staticTexts["player.error"].exists, "Player meldet einen Fehler")
        attach(app, "spielt")
        XCTAssertGreaterThan(second, first, "Die Zeit läuft nicht, es kommt kein Audio")
        app.buttons["Pause"].firstMatch.tap()
    }

    static func seconds(_ label: String) -> Int {
        label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }
}
