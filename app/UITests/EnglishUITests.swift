//
//  EnglishUITests.swift
//  PodcastAIUITests
//
//  Die App auf Englisch: Reiter, Überschriften und Mehrzahl kommen aus dem
//  Katalog, nicht aus dem deutschen Quelltext.
//

import XCTest

final class EnglishUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testEnglishTabsAndPlural() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        for name in ["For You", "Topic Updates", "My Podcasts", "Knowledge", "Chat"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Reiter „\(name)“ fehlt auf Englisch")
        }
        XCTAssertTrue(app.staticTexts["New in Your Subscriptions"].waitForExistence(timeout: 10))
        let plural = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'passages in this episode'")).firstMatch
        XCTAssertTrue(plural.waitForExistence(timeout: 10), "Mehrzahl auf Englisch fehlt")

        app.tabBars.buttons["My Podcasts"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Add Podcast"].firstMatch.waitForExistence(timeout: 5),
                      "„Add Podcast“ fehlt")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "englisch"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Deutsch bleibt Deutsch, mit richtiger Mehrzahl.
    func testGermanPlural() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        let plural = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Stellen in dieser Folge'")).firstMatch
        XCTAssertTrue(plural.waitForExistence(timeout: 10), "Mehrzahl auf Deutsch fehlt („2 Stellen“)")
    }
}
