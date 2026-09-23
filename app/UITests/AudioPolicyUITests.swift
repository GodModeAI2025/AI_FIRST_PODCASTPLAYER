//
//  AudioPolicyUITests.swift
//  PodcastAIUITests
//
//  TestFlight-Feedback zu 0.7.1: ältere Folgen eines Podcasts auf Wunsch
//  vorbereiten, die neueste Folge je Podcast für unterwegs behalten und
//  beide Regeln fürs Netz an einem Ort in den Einstellungen.
//

import XCTest

final class AudioPolicyUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Die Folgenliste bietet „Ältere Folgen auch vorbereiten“ an, fragt mit
    /// der Zahl der Folgen ohne Transkript nach, zeigt danach, dass es an
    /// ist, und lässt sich dort wieder ausschalten.
    @MainActor func testOlderEpisodesActionAsksFirstAndCanBeTurnedOff() {
        let app = XCUIApplication()
        // Ohne automatische Transkripte und ohne Vorhalten lädt im Simulator
        // nichts, und die zweite Beispielfolge bleibt ohne Transkript.
        app.launchArguments = ["-uitest-fresh", "-demo-content", "-automaticAnalysis", "NO",
                               "-keepNewestAudio", "NO"]
        app.launch()
        tab(app, "Meine Podcasts")
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()

        let prepare = app.buttons["episodes.prepareOlder"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 10),
                      "Die Folgenliste bietet „Ältere Folgen auch vorbereiten“ nicht an")
        prepare.tap()

        // Die Rückfrage nennt, wie viele Folgen noch ohne Transkript sind.
        let question = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '1 Folge noch ohne Transkript'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Die Rückfrage nennt die Zahl der Folgen nicht")
        attach(app, "rueckfrage-aeltere-folgen")
        app.buttons["Vorbereiten"].firstMatch.tap()

        let status = app.descendants(matching: .any)["episodes.olderStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "Die Folgenliste zeigt nicht, dass es an ist")
        let stop = app.buttons["episodes.stopOlder"]
        XCTAssertTrue(stop.exists, "„Ältere Folgen nicht mehr vorbereiten“ fehlt")
        attach(app, "aeltere-folgen-an")

        stop.tap()
        XCTAssertTrue(app.buttons["episodes.prepareOlder"].waitForExistence(timeout: 5),
                      "Nach dem Ausschalten fehlt der Knopf zum Einschalten")
        XCTAssertFalse(status.exists)
    }

    /// Unter Mobilfunk stehen beide Regeln fürs Netz untereinander, unter
    /// Speicher „Neueste Folge je Podcast behalten“, ab Werk an.
    @MainActor func testSettingsShowNetworkRulesTogetherAndKeepNewest() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        let gear = app.navigationBars.buttons["toolbar.settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Kein Zahnrad in „Für dich“")
        gear.tap()

        let cellular = app.switches["settings.cellular"]
        XCTAssertTrue(cellular.waitForExistence(timeout: 5))
        let preparation = app.switches["settings.preparationCellular"]
        XCTAssertTrue(preparation.exists, "Der Schalter fürs Vorbereiten über Mobilfunk fehlt")
        // Gleich unter „Abspielen und Laden über Mobilfunk“, im selben Abschnitt.
        XCTAssertGreaterThanOrEqual(preparation.frame.minY, cellular.frame.maxY - 1)
        XCTAssertLessThan(preparation.frame.minY - cellular.frame.maxY, 44,
                          "Der Schalter steht nicht direkt unter dem für Abspielen und Laden")
        // Ab Werk lädt die App von selbst nur im WLAN.
        XCTAssertEqual(preparation.value as? String, "0")
        XCTAssertFalse(app.switches["Nur im WLAN"].exists, "Der alte Schalter steht noch unter Transkripte")
        attach(app, "mobilfunk")

        let keepNewest = app.switches["settings.keepNewest"]
        for _ in 0..<6 where !keepNewest.exists || !keepNewest.isHittable { app.swipeUp() }
        XCTAssertTrue(keepNewest.exists, "„Neueste Folge je Podcast behalten“ fehlt unter Speicher")
        XCTAssertEqual(keepNewest.value as? String, "1")
        attach(app, "speicher")
    }
}
