//
//  StorageUITests.swift
//  PodcastAIUITests
//
//  Speicher und unterwegs hören: „Laden (offline)“ holt nur den Ton, und
//  „Audio entfernen“ lässt den Player stehen, auch wenn die Folge pausiert.
//

import XCTest

final class StorageUITests: XCTestCase {

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

    func testLoadOfflineThenRemoveAudioKeepsPausedPlayer() {
        let app = XCUIApplication(); app.launchArguments = ["-uitest-fresh"]; app.launch()
        addSource(app, "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=webplayer-download")
        let row = app.staticTexts["Einzelne Folgen"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()

        // Nur laden, ohne Transkript.
        let menu = app.buttons["episode.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let load = app.buttons["Laden (offline)"].firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 5), "„Laden (offline)“ fehlt im Menü")
        load.tap()
        let onDevice = app.staticTexts["Audio liegt auf diesem Gerät"].firstMatch
        XCTAssertTrue(onDevice.waitForExistence(timeout: 300), "Die Folge wurde nicht geladen")
        attach(app, "geladen")

        // Abspielen, pausieren, dann den Ton entfernen: der Player bleibt.
        app.buttons["episode.play"].tap()
        let miniBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["episode.play"].tap()
        menu.tap()
        let remove = app.buttons["Audio entfernen, Daten behalten"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(onDevice.waitForNonExistence(timeout: 10), "Das Audio liegt noch auf dem Gerät")
        XCTAssertTrue(miniBar.exists, "„Audio entfernen“ hat den Player geschlossen")
        attach(app, "entfernt, Player da")
    }
}
