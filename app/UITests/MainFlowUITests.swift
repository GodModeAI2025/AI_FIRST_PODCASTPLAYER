//
//  MainFlowUITests.swift
//  PodcastAIUITests
//
//  Der Hauptweg auf echtem Netz: Quelle hinzufügen, sie erscheint in der
//  Mediathek, ihre Folgen lassen sich öffnen. Dazu ein Durchgang durch
//  alle Tabs, damit keine Ansicht beim ersten Öffnen abstürzt.
//

import XCTest

final class MainFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testAllTabsOpen() {
        let app = XCUIApplication()
        app.launch()
        for tab in ["Meine Feeds", "Mediathek", "Wissen", "Für dich"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.state == .runningForeground, "Absturz beim Öffnen von \(tab)")
        }
        app.tabBars.buttons["Fragen"].firstMatch.tap()
        XCTAssertTrue(app.state == .runningForeground)
    }

    func testAddFeedShowsSourceAndEpisodes() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Mediathek"].tap()

        app.navigationBars.buttons["Quelle hinzufügen"].firstMatch.tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://feeds.npr.org/510289/podcast.xml")
        app.buttons["Hinzufügen"].tap()

        let row = app.staticTexts["Planet Money"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Quelle erscheint nicht in der Mediathek")
        row.tap()

        // Mindestens eine Folgenzeile muss erscheinen.
        let anyCell = app.cells.element(boundBy: 0)
        XCTAssertTrue(anyCell.waitForExistence(timeout: 15), "Keine Folgen sichtbar")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
