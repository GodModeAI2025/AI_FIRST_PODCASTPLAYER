//
//  TagTrendsUITests.swift
//  PodcastAIUITests
//
//  „Angesagt“ und „Neu“ seit 0.12. Mit `-demo-trends` trägt „KI-Verordnung“
//  in dieser Woche Kapitel aus vier Quellen und ist damit angesagt; die
//  Seite „Datenschutz“ war vor zwei Tagen zuletzt offen, und die
//  Beispielfolge ist danach erschienen. Mit dem Trend entsteht von selbst
//  das Themen-Update „Angesagt“.
//
//  Nichts davon spielt Ton.
//

import XCTest

final class TagTrendsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-demo-trends"]
        app.launch()
        return app
    }

    /// Auf dem iPad liegen die Tabs oben und erscheinen nicht unter `tabBars`.
    @MainActor private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    @MainActor private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func openMyTags(_ app: XCUIApplication) {
        tab(app, "Wissen")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Meine Tags'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    @MainActor private func assertNoAudio(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch.exists,
                       "„Angesagt“ hat Ton gestartet")
    }

    /// „Meine Tags“ beginnt mit „Angesagt“, ein Tipp öffnet die Tag-Seite,
    /// und die sagt, dass das Tag angesagt ist.
    @MainActor func testTrendingGroupInMyTags() {
        let app = launch()
        openMyTags(app)

        let trending = element(app, "tags.trending.KI-Verordnung")
        XCTAssertTrue(trending.waitForExistence(timeout: 10), "In „Meine Tags“ fehlt „Angesagt“")
        let followed = element(app, "tags.row.Datenschutz")
        XCTAssertTrue(followed.waitForExistence(timeout: 5))
        XCTAssertLessThan(trending.frame.minY, followed.frame.minY, "„Angesagt“ steht nicht oben")
        XCTAssertFalse(element(app, "tags.trending.Datenschutz").exists, "Ein Tag ohne Trend steht unter „Angesagt“")
        attach(app, "meine-tags-angesagt")

        trending.tap()
        XCTAssertTrue(app.navigationBars["KI-Verordnung"].waitForExistence(timeout: 5), "Die Tag-Seite öffnet nicht")
        XCTAssertTrue(element(app, "tag.trending").waitForExistence(timeout: 5), "Die Tag-Seite sagt nicht, dass das Tag angesagt ist")
        assertNoAudio(app)
    }

    /// Der Tab „Themen-Updates“ zeigt oben „Angesagt: …“, ein Tipp auf den
    /// Namen öffnet die Tag-Seite.
    @MainActor func testTrendingLineInTopicUpdates() {
        let app = launch()
        tab(app, "Themen-Updates")

        let name = element(app, "topicUpdates.trending.KI-Verordnung")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Im Kopf der Themen-Updates fehlt „Angesagt“")
        attach(app, "themen-updates-angesagt")
        name.tap()
        XCTAssertTrue(app.navigationBars["KI-Verordnung"].waitForExistence(timeout: 5), "Die Tag-Seite öffnet nicht")
        assertNoAudio(app)
    }

    /// Sobald etwas angesagt ist, legt die App das Update „Angesagt“ von
    /// selbst an. Seine Seite nennt das angesagte Tag und lässt sich nicht
    /// bearbeiten. „Ausschalten“ löscht es, der Schalter legt es wieder an,
    /// und bei alledem spielt nichts.
    @MainActor func testTrendingFeedFollowsTrends() {
        let app = launch()
        tab(app, "Themen-Updates")

        let toggle = element(app, "topicUpdates.trendingFeed.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Der Schalter für „Angesagt“ fehlt")
        let row = element(app, "topicUpdates.trendingFeed.row")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "„Angesagt“ entstand nicht von selbst")
        XCTAssertEqual(toggle.value as? String, "1", "Der Schalter steht nicht auf an")
        attach(app, "angesagt-update")

        row.tap()
        XCTAssertTrue(app.navigationBars["Angesagt"].waitForExistence(timeout: 5), "Die Seite von „Angesagt“ öffnet nicht")
        let mode = element(app, "smartFeed.mode")
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.label.contains("angesagten Tags"), "Die Seite sagt nicht, woher die Tags kommen: \(mode.label)")
        XCTAssertTrue(element(app, "topicUpdates.stat.KI-Verordnung").waitForExistence(timeout: 5),
                      "Das angesagte Tag steht nicht auf der Seite")
        attach(app, "angesagt-seite")
        assertNoAudio(app)

        // Die Tags kommen aus den Trends: kein „Bearbeiten“, dafür „Ausschalten“.
        app.navigationBars.buttons["Mehr"].firstMatch.tap()
        let turnOff = app.buttons["Ausschalten"].firstMatch
        XCTAssertTrue(turnOff.waitForExistence(timeout: 5), "Im Menü fehlt „Ausschalten“")
        XCTAssertFalse(app.buttons["Bearbeiten"].exists, "„Angesagt“ lässt sich von Hand bearbeiten")
        turnOff.tap()
        XCTAssertTrue(app.staticTexts["„Angesagt“ ausschalten?"].firstMatch.waitForExistence(timeout: 5),
                      "Keine Rückfrage vor dem Ausschalten")
        app.buttons["Ausschalten"].firstMatch.tap()

        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Nach dem Ausschalten geht es nicht zurück zur Liste")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Ausgeschaltet steht „Angesagt“ noch da")
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(element(app, "topicUpdates.trending.KI-Verordnung").exists,
                      "Mit dem Update verschwand auch die Zeile „Angesagt“")
        attach(app, "angesagt-aus")
        assertNoAudio(app)

        // Der Schalter selbst liegt am rechten Rand der Zeile.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Eingeschaltet entsteht „Angesagt“ nicht wieder")
        XCTAssertEqual(toggle.value as? String, "1")
        assertNoAudio(app)
    }

    /// Die Seite „Datenschutz“ zählt die neue Aussage seit dem letzten
    /// Besuch. Beim nächsten Öffnen ist sie nicht mehr neu.
    @MainActor func testNewSinceLastVisit() {
        let app = launch()
        openMyTags(app)

        let row = element(app, "tags.row.Datenschutz")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Datenschutz"].waitForExistence(timeout: 5))
        let news = element(app, "tag.news")
        XCTAssertTrue(news.waitForExistence(timeout: 10), "Die Tag-Seite zählt nichts als neu")
        XCTAssertTrue(news.label.contains("1 neu seit deinem letzten Besuch"), "Falsche Zahl: \(news.label)")
        attach(app, "tag-seite-neu")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Datenschutz"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "tag.chapter").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "tag.news").exists, "Nach dem Besuch ist die Aussage noch neu")
        assertNoAudio(app)
    }
}
