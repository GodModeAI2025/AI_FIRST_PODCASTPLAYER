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

    func testPodigeeFeedURLWithoutFeedIsDiscovered() {
        let app = XCUIApplication(); app.launch()
        addSource(app, "https://think-ai.podigee.io/rssfeed")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Think'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Podigee-Feed nicht gefunden")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach(app, "podigee")
    }

    func testDirectMP3BecomesSingleEpisode() {
        let app = XCUIApplication(); app.launch()
        addSource(app, "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=webplayer-download")
        let row = app.staticTexts["Einzelne Folgen"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "MP3 nicht als Einzelfolge angelegt")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        row.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Erschliessen'")).firstMatch.waitForExistence(timeout: 10))
        attach(app, "mp3")
    }

    func testYouTubeChannelOffersAudioPodcast() {
        let app = XCUIApplication(); app.launch()
        addSource(app, "https://www.youtube.com/channel/UCDx6L69jmKBJbNu5GnkCilg")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Magnussen'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let offer = app.staticTexts["Als Audio-Podcast verfügbar"].firstMatch
        let offerHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Audio-Podcast'")).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 20) || offerHeader.exists, "Kein Audio-Podcast angeboten")
        attach(app, "youtube")
    }

    func testTopicCanBeCreatedInsideTopicUpdate() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["Meine Feeds"].tap()
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Neue KI Modelle")
        let topic = app.textFields["Neues Thema, z. B. KI-Modelle"]
        topic.tap(); topic.typeText("KI-Modelle")
        app.buttons.matching(NSPredicate(format: "label == 'Hinzufügen'")).firstMatch.tap()
        let create = app.navigationBars.buttons["Anlegen"]
        let deadline = Date().addingTimeInterval(10)
        while !create.isEnabled && Date() < deadline { sleep(1) }
        XCTAssertTrue(create.isEnabled, "Anlegen bleibt gesperrt")
        attach(app, "themen")
        create.tap()
        XCTAssertTrue(app.staticTexts["Neue KI Modelle"].firstMatch.waitForExistence(timeout: 10))
    }
}
