//
//  BetaFeedback11UITests.swift
//  PodcastAIUITests
//
//  Rückmeldungen aus TestFlight 0.7 bis 0.11, nachgestellt mit den
//  Beispielinhalten: Abschnitte in „Für dich“ mit Überschrift und Satz,
//  die Seite eines Podcasts ohne „Keine Folgen“ über der Beschreibung und
//  der Überblick einer Folge mit lesbarem Hauptknopf.
//

import XCTest

final class BetaFeedback11UITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        return app
    }

    /// „Die Rubriken unten müssen optisch besser hergeleitet werden“: jeder
    /// Abschnitt hat eine Überschrift mit Satz, die Tags darunter ihre Zahl.
    @MainActor func testForYouSectionsAreIntroduced() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Neu in deinen Abos"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Die neuesten Folgen der Podcasts, die du abonniert hast."].exists,
                      "Unter „Neu in deinen Abos“ fehlt der erklärende Satz")
        attach(app, "fuer-dich-oben")
        let tags = app.staticTexts["Zu deinen Tags"].firstMatch
        for _ in 0..<6 where !tags.isHittable { app.swipeUp() }
        XCTAssertTrue(tags.exists, "Die Überschrift „Zu deinen Tags“ fehlt")
        XCTAssertTrue(app.buttons["forYou.interests"].firstMatch.exists, "„Tags bearbeiten“ fehlt")
        attach(app, "fuer-dich-tags")
    }

    /// „Grafische Überlagerung“: auf der Seite eines Podcasts mit Folgen steht
    /// nie „Keine Folgen“. Der Überblick einer Folge zeigt den Hauptknopf.
    @MainActor func testPodcastPageAndEpisodeOverview() {
        let app = launch()
        app.tabBars.buttons["Meine Podcasts"].tap()
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["episodes.empty"].exists,
                       "„Keine Folgen“ steht über einer Liste mit Folgen")
        attach(app, "podcast-seite")
        episode.tap()
        XCTAssertTrue(app.buttons["episode.play"].waitForExistence(timeout: 10), "Kein Abspielen-Knopf")
        attach(app, "folge-ueberblick")
    }
}
