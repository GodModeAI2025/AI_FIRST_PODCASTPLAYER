//
//  TagsUITests.swift
//  PodcastAIUITests
//
//  Tags seit 0.10: Plus folgt einem Tag, Minus beendet das, das Tag bleibt
//  sichtbar. Die Tag-Seite öffnet sich aus der Wolke und aus „Meine Tags“.
//  Ein Feld, in das man Themen eintippt, gibt es nicht mehr.
//
//  Die Beispielfolge bringt feste Kapitel-Tags mit, ohne Modell: Datenschutz
//  (gefolgt), Sprachmodelle, Automatisierung, Haftung, KI-Verordnung.
//

import XCTest

final class TagsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-demo-content"]
        app.launch()
        return app
    }

    /// Auf dem iPad liegen die Tabs oben und erscheinen nicht unter `tabBars`.
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

    @MainActor private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Öffnet die Beispielfolge im Überblick.
    @MainActor private func openDemoEpisode(_ app: XCUIApplication) {
        tab(app, "Meine Podcasts")
        let source = app.staticTexts["Beispiel: Arbeit und KI"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'KI im Arbeitsalltag'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()
        XCTAssertTrue(app.segmentedControls["episode.sections"].waitForExistence(timeout: 10))
    }

    /// Bis ein Element erscheint, nach unten wischen, höchstens ein paar Mal.
    @MainActor private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if target.waitForExistence(timeout: 2), target.isHittable { return true }
            app.swipeUp()
        }
        return target.exists
    }

    /// Plus in „Kurz gesagt“ folgt einem neutralen Tag, Minus beendet das,
    /// und das Tag bleibt in der Wolke.
    @MainActor func testFollowAndUnfollowTagInCloud() {
        let app = launchDemo()
        openDemoEpisode(app)

        let follow = element(app, "tag.follow.Haftung")
        XCTAssertTrue(scrollTo(follow, in: app), "In „Kurz gesagt“ fehlt das Tag Haftung mit Plus")
        // Gefolgt ist in der Beispielfolge schon Datenschutz, mit Minus.
        XCTAssertTrue(element(app, "tag.unfollow.Datenschutz").exists, "Das gefolgte Tag trägt kein Minus")
        attach(app, "tag-wolke")

        follow.tap()
        let unfollow = element(app, "tag.unfollow.Haftung")
        XCTAssertTrue(unfollow.waitForExistence(timeout: 5), "Nach Plus trägt das Tag kein Minus")

        unfollow.tap()
        XCTAssertTrue(element(app, "tag.follow.Haftung").waitForExistence(timeout: 5),
                      "Nach Minus ist das Tag nicht wieder neutral")
        XCTAssertTrue(element(app, "tag.open.Haftung").exists, "Nach Minus ist das Tag verschwunden")

        // Nichts davon spielt Ton.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch.exists,
                       "Die Tag-Wolke hat Ton gestartet")
    }

    /// Jedes Kapitel trägt seine Tags, und ein Tipp auf den Namen öffnet
    /// die Tag-Seite mit den Kapiteln, in denen es vorkommt.
    @MainActor func testTagPageOpensFromChapter() {
        let app = launchDemo()
        openDemoEpisode(app)
        app.segmentedControls["episode.sections"].buttons["Kapitel"].tap()

        let open = element(app, "tag.open.KI-Verordnung")
        XCTAssertTrue(scrollTo(open, in: app), "Am Kapitel fehlt das Tag KI-Verordnung")
        attach(app, "kapitel-tags")
        open.tap()

        XCTAssertTrue(app.navigationBars["KI-Verordnung"].waitForExistence(timeout: 5), "Die Tag-Seite öffnet nicht")
        let chapter = element(app, "tag.chapter")
        XCTAssertTrue(chapter.waitForExistence(timeout: 5), "Auf der Tag-Seite fehlt das Kapitel")
        attach(app, "tag-seite")

        // Ein Tipp öffnet die Folge bei ihren Kapiteln, ohne Ton.
        chapter.tap()
        XCTAssertTrue(app.segmentedControls["episode.sections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["episode.sections"].buttons["Kapitel"].isSelected,
                      "Die Folge öffnet nicht bei den Kapiteln")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Player öffnen'")).firstMatch.exists,
                       "Die Tag-Seite hat Ton gestartet")
    }

    /// „Meine Tags“: gefolgte oben, neutrale mit Zahl darunter, Suche, und
    /// die Seite eines Tags. Ein Feld für neue Themen gibt es nicht.
    @MainActor func testMyTagsListAndNoFreeText() {
        let app = launchDemo()
        tab(app, "Wissen")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Meine Tags'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let followed = element(app, "tags.row.Datenschutz")
        XCTAssertTrue(followed.waitForExistence(timeout: 10), "Das gefolgte Tag fehlt")
        let neutral = element(app, "tags.row.Sprachmodelle")
        XCTAssertTrue(neutral.waitForExistence(timeout: 5), "Das neutrale Tag fehlt")
        XCTAssertLessThan(followed.frame.minY, neutral.frame.minY, "Gefolgte Tags stehen nicht oben")
        XCTAssertFalse(app.textFields["interest.new"].exists, "Es gibt wieder ein Feld für neue Themen")
        XCTAssertFalse(app.textFields["z. B. Datenschutz"].exists)
        attach(app, "meine-tags")

        neutral.tap()
        XCTAssertTrue(app.navigationBars["Sprachmodelle"].waitForExistence(timeout: 5), "Die Tag-Seite öffnet nicht")
        XCTAssertFalse(app.textFields["interest.keyword"].exists, "Die Tag-Seite hat wieder ein Stichwortfeld")
        let follow = element(app, "tag.follow.Sprachmodelle")
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.tap()
        XCTAssertTrue(element(app, "tag.unfollow.Sprachmodelle").waitForExistence(timeout: 5),
                      "Plus auf der Tag-Seite folgt nicht")
    }

    /// Im Blatt für ein Themen-Update stehen die gefolgten Tags zur Auswahl,
    /// ein Feld für ein neues Thema gibt es nicht.
    @MainActor func testTopicUpdateSheetHasNoFreeTextTopic() {
        let app = launchDemo()
        tab(app, "Themen-Updates")
        app.navigationBars.buttons["Neu"].firstMatch.tap()
        let name = app.textFields["z. B. Mein KI Update"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Neues Thema, z. B. KI-Modelle"].exists, "Es gibt wieder ein Feld für neue Themen")
        XCTAssertEqual(app.textFields.count, 1, "Außer dem Namen gibt es ein weiteres Eingabefeld")
        XCTAssertTrue(app.buttons["Datenschutz"].firstMatch.waitForExistence(timeout: 5),
                      "Das gefolgte Tag steht nicht zur Auswahl")
        attach(app, "themen-update-tags")
        app.navigationBars.buttons["Abbrechen"].firstMatch.tap()
    }
}
