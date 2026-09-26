//
//  WidgetLinkUITests.swift
//  PodcastAIUITests
//
//  Die Adressen, mit denen das Widget „Was ist neu“ die App öffnet:
//  `podcastai://topicupdates` wechselt zu den Themen-Updates,
//  `podcastai://tag/<Kennung>` öffnet dort die Seite des Tags. Keine der
//  beiden spielt etwas ab.
//

import XCTest

final class WidgetLinkUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-skip-onboarding"]
        app.launch()
        return app
    }

    @MainActor func testTopicUpdatesLinkOpensTheTabWithoutPlaying() throws {
        let app = launchFresh()
        app.open(try XCTUnwrap(URL(string: "podcastai://topicupdates")))
        XCTAssertTrue(app.navigationBars["Themen-Updates"].waitForExistence(timeout: 10),
                      "Die Adresse aus dem Widget öffnet die Themen-Updates nicht")
        XCTAssertFalse(app.buttons["focusbar.open"].exists, "Eine Adresse aus dem Widget hat Ton gestartet")
    }

    /// Eine Kennung, die es nicht gibt, führt auf die Tag-Seite mit ihrem
    /// Hinweis, nicht ins Leere.
    @MainActor func testTagLinkOpensTheTagPage() throws {
        let app = launchFresh()
        app.open(try XCTUnwrap(URL(string: "podcastai://tag/unbekannt-1")))
        XCTAssertTrue(app.descendants(matching: .any)["tag.page"].firstMatch.waitForExistence(timeout: 10),
                      "Die Adresse aus dem Widget öffnet die Tag-Seite nicht")
        XCTAssertTrue(app.staticTexts["Tag nicht gefunden"].exists)
        XCTAssertFalse(app.buttons["focusbar.open"].exists, "Eine Adresse aus dem Widget hat Ton gestartet")
    }

    /// Fremde Adressen mit demselben Schema bleiben ohne Wirkung.
    @MainActor func testForeignLinkChangesNothing() throws {
        let app = launchFresh()
        let forYou = app.navigationBars["Für dich"]
        XCTAssertTrue(forYou.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "podcastai://play/123")))
        XCTAssertTrue(forYou.waitForExistence(timeout: 5), "Eine fremde Adresse hat den Tab gewechselt")
        XCTAssertFalse(app.buttons["focusbar.open"].exists)
    }
}
