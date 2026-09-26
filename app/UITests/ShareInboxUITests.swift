//
//  ShareInboxUITests.swift
//  PodcastAIUITests
//
//  „An PodcastAI senden“ aus Sicht der App: Die Erweiterung hat etwas in
//  den Eingang gelegt, die App zeigt es beim Start. Ein Link öffnet die
//  Vorschau, abonniert wird erst auf Tippen. Eine Audiodatei kommt nach
//  „Zur Bibliothek hinzufügen“ unter „Einzelne Folgen“.
//
//  Das Teilen-Menü selbst lässt sich im UI-Test nicht bedienen. Die
//  Startargumente `-uitest-shared-link` und `-uitest-shared-audio` legen
//  deshalb dieselben Einträge an wie die Erweiterung. Beide Tests laufen mit
//  `-catalog-fixtures` ohne Netz.
//

import XCTest

final class ShareInboxUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-catalog-fixtures", "-automaticAnalysis", "NO"] + arguments
        app.launch()
        return app
    }

    /// Ein geteilter Feed zeigt die Vorschau mit „Abonnieren“, statt gleich
    /// zu abonnieren.
    @MainActor func testSharedFeedOpensPreview() {
        let app = launch(["-uitest-shared-link", "https://example.com/feeds/code-und-kaffee.xml"])

        let subscribe = app.buttons["link.subscribe"].firstMatch
        XCTAssertTrue(subscribe.waitForExistence(timeout: 15), "Zum geteilten Link fehlt die Vorschau")
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Code und Kaffee'")).firstMatch
        XCTAssertTrue(title.exists, "Die Vorschau zeigt nicht den Podcast aus dem Link")
        XCTAssertFalse(app.descendants(matching: .any)["link.subscribe.done"].exists,
                       "Der Podcast war abonniert, bevor jemand getippt hat")
        attach(app, "geteilter-feed-vorschau")

        subscribe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["link.subscribe.done"].waitForExistence(timeout: 10),
                      "„Abonnieren“ in der Vorschau hat nicht abonniert")
        attach(app, "geteilter-feed-abonniert")
    }

    /// Eine geteilte Audiodatei kommt erst nach dem Tipp in die Bibliothek.
    @MainActor func testSharedAudioFileNeedsConfirmation() {
        let app = launch(["-uitest-shared-audio", "Sprachmemo Interview.mp3"])

        let add = app.buttons["share.audio.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "Zur geteilten Audiodatei fehlt das Blatt")
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Sprachmemo Interview'")).firstMatch
        XCTAssertTrue(title.exists, "Der Titel kommt nicht aus dem Dateinamen")
        attach(app, "geteilte-audiodatei")

        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 10), "Das Blatt bleibt nach dem Hinzufügen offen")
        let tab = app.tabBars.buttons["Meine Podcasts"]
        (tab.exists ? tab : app.buttons["Meine Podcasts"].firstMatch).tap()
        let source = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Einzelne Folgen'")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Die Datei steht nicht unter „Einzelne Folgen“")
        attach(app, "geteilte-audiodatei-bibliothek")
    }
}
