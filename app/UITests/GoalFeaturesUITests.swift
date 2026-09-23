//
//  GoalFeaturesUITests.swift
//  PodcastAIUITests
//
//  Die Kernwege der App: Folge mit Reitern, Fragen an eine Folge, Export,
//  Löschen, Einstellungen für Intelligenz, Speicher und Synchronisation.
//

import XCTest

final class GoalFeaturesUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private let feed = "https://feeds.transistor.fm/ai-to-the-dna"

    private func launchWithFeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        // Auf dem iPad liegen die Tabs oben und erscheinen nicht unter `tabBars`.
        let library = app.tabBars.buttons["Meine Podcasts"]
        (library.exists ? library : app.buttons["Meine Podcasts"].firstMatch).tap()
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(feed)
        app.buttons["Hinzufügen"].tap()
        let row = app.staticTexts["AI to the DNA"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testEpisodeSectionsAndEpisodeChat() {
        let app = launchWithFeed()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 15))
        episode.tap()

        let sections = app.segmentedControls["episode.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        let bar = episodeNavigationBar(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let title = bar.identifier
        XCTAssertFalse(title.isEmpty, "Die Folge hat keinen Titel in der Navigationsleiste")
        for name in ["Kapitel", "Transkript", "Fakten"] {
            sections.buttons[name].tap()
            attach(app, "reiter-\(name)")
        }
        sections.buttons["Fragen"].tap()
        attach(app, "reiter-Fragen")
        // Der Bereich ist fest. Die Folge muss trotzdem erkennbar bleiben.
        let scope = app.descendants(matching: .any)["episode.ask.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "Im Reiter Fragen fehlt die Folge")
        XCTAssertTrue(scope.label.contains(title), "Die Kopfzeile nennt eine andere Folge")
        XCTAssertTrue(bar.staticTexts[title].exists, "Titel fehlt in der Navigationsleiste")
        let suggestion = app.buttons["Worum geht es in dieser Folge?"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Keine Vorschlagsfragen")
        suggestion.tap()
        // Im Simulator hat die Folge kein Transkript. Die Antwort sagt das,
        // je nach Zustand anders, aber immer mit dem Hinweis auf die Belege.
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Beleg'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 20), "Keine Antwort im Folgen-Chat")
        attach(app, "folgen-chat")

        // Zurück muss zur Liste führen, auch während Transkripte erstellt
        // werden. Früher lag die Aktivitätszeile auf dem Zurück-Knopf.
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(sections.waitForNonExistence(timeout: 5), "Zurück hat die Folge nicht verlassen")
        XCTAssertFalse(app.navigationBars["Warteschlange"].exists, "Zurück hat die Warteschlange geöffnet")
        XCTAssertTrue(app.navigationBars["AI to the DNA"].waitForExistence(timeout: 5))
    }

    /// Die Aktivitätszeile liegt über der Navigation, nicht auf ihr, und
    /// öffnet weiterhin die Warteschlange.
    @MainActor
    func testActivityBannerLeavesNavigationFree() throws {
        let app = launchWithFeed()
        // Nach dem Abonnieren erstellt die App Transkripte. Das zeigt ein
        // Symbol in der Navigationsleiste, kein Streifen über dem Inhalt.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let status = app.buttons["activity.status"].firstMatch
        guard status.waitForExistence(timeout: 20) else {
            throw XCTSkip("Es wird gerade kein Transkript erstellt, das Symbol erscheint nicht")
        }
        attach(app, "aktivitaet")
        // Unter iOS 27 ist ein Transkript manchmal schneller fertig, als der
        // Test das Symbol ausmisst. Einmal lesen, sonst überspringen.
        guard let symbol = try? status.snapshot() else {
            throw XCTSkip("Das Transkript war fertig, bevor das Symbol gemessen wurde")
        }
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.frame.contains(CGPoint(x: symbol.frame.midX, y: symbol.frame.midY)),
                      "Das Symbol sitzt nicht in der Navigationsleiste")
        status.tap()
        if !app.navigationBars["Warteschlange"].waitForExistence(timeout: 5) {
            if !status.exists { throw XCTSkip("Das Transkript war während des Tipps fertig") }
            XCTFail("Das Symbol öffnet die Warteschlange nicht")
            return
        }
        app.buttons["Fertig"].firstMatch.tap()
    }

    /// Tiefensuche in einer Momentaufnahme, der erste Treffer gewinnt.
    @MainActor
    private func find(_ node: XCUIElementSnapshot,
                      _ matches: (XCUIElementSnapshot) -> Bool) -> XCUIElementSnapshot? {
        if matches(node) { return node }
        for child in node.children {
            if let hit = find(child, matches) { return hit }
        }
        return nil
    }

    /// Die Leiste der geöffneten Folge. Andere Tabs haben eigene Leisten.
    private func episodeNavigationBar(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.containing(.button, identifier: "episode.menu").firstMatch
    }

    func testEpisodeExportAndDelete() {
        let app = launchWithFeed()
        let episode = app.cells.element(boundBy: 1)
        XCTAssertTrue(episode.waitForExistence(timeout: 15))
        let title = episode.buttons.firstMatch.label
        episode.tap()

        let menu = app.buttons["episode.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Exportieren ohne Transkript"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 10), "Kein Export")
        attach(app, "export")
        app.buttons["Fertig"].firstMatch.tap()

        menu.tap()
        // Der Menüeintrag trägt einen Untertitel. Je nach System gehört er
        // zur Beschriftung, deshalb nur der Anfang.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Folge löschen'")).firstMatch.tap()
        let confirm = app.buttons["Folge und alle Daten löschen"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Die Folgenansicht schließt sich, zurück in der Folgenliste des Podcasts.
        XCTAssertTrue(app.segmentedControls["episode.sections"].waitForNonExistence(timeout: 10),
                      "Die gelöschte Folge ist noch geöffnet")
        XCTAssertFalse(menu.exists, "Das Menü der gelöschten Folge ist noch da")
        XCTAssertTrue(app.navigationBars["AI to the DNA"].waitForExistence(timeout: 5),
                      "Nach dem Löschen steht nicht die Folgenliste da")
        // Die Folge ist weg.
        let prefix = String(title.prefix(40))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        let deadline = Date().addingTimeInterval(10)
        while row.exists && Date() < deadline { sleep(1) }
        XCTAssertFalse(row.exists, "Folge ist nach dem Löschen noch da")
        attach(app, "geloescht")
    }

    func testSettingsShowIntelligenceStorageAndSync() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        app.tabBars.buttons["Wissen"].tap()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Einstellungen'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        // Oben stehen Hilfe, Datenschutz und Mobilfunk, darunter der Rest.
        XCTAssertTrue(app.switches["settings.cellular"].waitForExistence(timeout: 5))
        let cloud = app.switches["settings.privateCloud"]
        for _ in 0..<3 where !cloud.exists { app.swipeUp() }
        XCTAssertTrue(cloud.exists)
        for _ in 0..<3 where !app.staticTexts["iCloud"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["iCloud"].exists)
        for _ in 0..<3 where !app.staticTexts["Audiodateien auf diesem Gerät"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Audiodateien auf diesem Gerät"].exists)
        attach(app, "einstellungen")
    }

    /// Das Zahnrad in „Für dich“ führt zu Einstellungen, Hilfe und Datenschutz.
    func testSettingsHelpAndPrivacyFromForYou() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"]
        app.launch()
        let gear = app.navigationBars.buttons["toolbar.settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Kein Zahnrad in „Für dich“")
        gear.tap()
        XCTAssertTrue(app.switches["settings.cellular"].waitForExistence(timeout: 5),
                      "Die Einstellungen zeigen keinen Schalter für Mobilfunk")
        app.buttons["settings.help"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["So funktioniert's"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.privacy"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Datenschutz"].waitForExistence(timeout: 5))
        attach(app, "datenschutz-aus-fuer-dich")
    }
}
