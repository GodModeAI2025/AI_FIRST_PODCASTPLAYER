//
//  CatalogUITests.swift
//  PodcastAIUITests
//
//  Der Podcast-Katalog im Blatt „Podcast hinzufügen“: Angesagt, Kategorien,
//  die Liste einer Kategorie und die Seite eines Podcasts.
//
//  Mit `-catalog-fixtures` antwortet der Katalog aus festen Daten. Der Test
//  braucht so weder Netz noch Zugang zu Podcast Index und sieht jedes Mal
//  dieselben ausgedachten Podcasts.
//

import XCTest

final class CatalogUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    private func openAddSheet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-catalog-fixtures"]
        app.launch()
        tab(app, "Meine Podcasts")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        return app
    }

    /// Scrollt, bis das Element antippbar ist. Die Liste lädt Zeilen erst,
    /// wenn sie sichtbar werden.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var left = attempts
        while !(element.exists && element.isHittable) && left > 0 {
            app.swipeUp()
            left -= 1
        }
    }

    /// Angesagt und Kategorien stehen da, eine Kategorie öffnet ihre Liste,
    /// ein Podcast daraus seine Seite mit „Abonnieren“ und den neuesten Folgen.
    func testBrowseCategoryAndOpenPodcast() {
        let app = openAddSheet()

        let card = app.buttons["catalog.trending.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Angesagt fehlt im Blatt")
        XCTAssertTrue(app.buttons["source.importOPML"].exists, "Der OPML-Import steht nicht mehr vor dem Katalog")
        attach(app, "katalog-start")

        let news = app.buttons["catalog.category.news"]
        scrollTo(news, in: app)
        XCTAssertTrue(news.isHittable, "Die Kategorie Nachrichten fehlt")
        XCTAssertTrue(app.buttons["catalog.category.trueCrime"].exists, "Nicht alle Kategorien stehen da")
        attach(app, "katalog-kategorien")
        news.tap()

        let subscribe = app.buttons.matching(NSPredicate(format: "label ENDSWITH ' abonnieren'")).firstMatch
        XCTAssertTrue(subscribe.waitForExistence(timeout: 10), "Die Kategorie zeigt keine Podcasts")
        XCTAssertTrue(app.buttons["Morgenlage abonnieren"].exists, "Der deutsche Nachrichten-Podcast fehlt")
        XCTAssertFalse(app.buttons["Morning Signal abonnieren"].exists, "Ein englischer Podcast steht unter Deutsch")
        XCTAssertTrue(app.descendants(matching: .any)["catalog.attribution"].firstMatch.exists,
                      "Der Hinweis auf Podcast Index fehlt")
        attach(app, "katalog-nachrichten")

        app.buttons["catalog.row"].firstMatch.tap()
        let detailSubscribe = app.buttons["source.preview.subscribe"]
        XCTAssertTrue(detailSubscribe.waitForExistence(timeout: 10), "Die Seite des Podcasts bietet kein Abonnieren")
        XCTAssertTrue(detailSubscribe.label.contains("Abonnieren"), "Der Knopf heißt nicht „Abonnieren“")
        let summary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Die Nachrichten des Tages'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Die Beschreibung fehlt")
        attach(app, "katalog-podcast")
        // Die Folgen stehen unter Beschreibung und Angaben, oft außerhalb des Bildschirms.
        let episode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Folge 40'")).firstMatch
        scrollTo(episode, in: app)
        XCTAssertTrue(episode.exists, "Die neuesten Folgen fehlen")
        XCTAssertFalse(app.buttons["episode.play"].exists, "Aus dem Katalog lässt sich etwas abspielen")
    }

    /// Die Suche zeigt Treffer aus dem Katalog, ohne aufgegebene Feeds und
    /// ohne Musik, und bietet für jeden „Abonnieren“.
    func testSearchShowsCatalogResults() {
        let app = openAddSheet()
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("kaffee")
        XCTAssertTrue(app.buttons["Code und Kaffee abonnieren"].waitForExistence(timeout: 10),
                      "Kein Treffer aus dem Katalog")
        XCTAssertTrue(app.buttons["Kaffeeklatsch abonnieren"].exists)
        XCTAssertFalse(app.buttons["Alter Funkturm abonnieren"].exists, "Ein aufgegebener Feed steht in den Treffern")
        XCTAssertFalse(app.buttons["Beat Kaffee abonnieren"].exists, "Ein Musik-Feed steht in den Treffern")
        attach(app, "katalog-suche")
    }
}
