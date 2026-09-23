//
//  CatalogUITests.swift
//  PodcastAIUITests
//
//  Der Podcast-Katalog im Blatt „Podcast hinzufügen“: Angesagt, Kategorien,
//  die Liste einer Kategorie, die Seite eines Podcasts und die Suche bei
//  Apple und Podcast Index.
//
//  Mit `-catalog-fixtures` antworten Charts, Einzelheiten, beide Suchen und
//  die Feeds aus festen Daten. Der Test braucht so kein Netz und sieht
//  jedes Mal dieselben ausgedachten Podcasts, als stünde das Gerät in
//  Deutschland.
//

import XCTest

final class CatalogUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name]
        (button.exists ? button : app.buttons[name].firstMatch).tap()
    }

    @MainActor private func openAddSheet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh", "-catalog-fixtures"]
        app.launch()
        tab(app, "Meine Podcasts")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        return app
    }

    /// Scrollt, bis das Element antippbar ist. Die Liste lädt Zeilen erst,
    /// wenn sie sichtbar werden.
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var left = attempts
        while !(element.exists && element.isHittable) && left > 0 {
            app.swipeUp()
            left -= 1
        }
    }

    @MainActor private func subscribeButtons(_ app: XCUIApplication, for title: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label == %@", "\(title) abonnieren"))
    }

    /// Angesagt und Kategorien stehen da, eine Kategorie öffnet ihre Charts,
    /// ein Podcast daraus seine Seite mit „Abonnieren“ und den neuesten
    /// Folgen, aber ohne etwas zum Abspielen.
    @MainActor func testBrowseCategoryAndOpenPodcast() {
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
        XCTAssertTrue(subscribeButtons(app, for: "Morgenlage").firstMatch.exists, "Die Charts der Nachrichten fehlen")
        XCTAssertTrue(subscribeButtons(app, for: "Morning Signal").firstMatch.exists,
                      "Die Charts einer Kategorie hängen nicht an der Sprache")
        XCTAssertFalse(subscribeButtons(app, for: "Ohne Feed").firstMatch.exists,
                       "Ein Platz ohne Feed steht in der Liste")
        XCTAssertTrue(app.descendants(matching: .any)["catalog.attribution"].firstMatch.exists,
                      "Der Hinweis auf Apple Podcasts und Podcast Index fehlt")
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

    /// Die Suche fragt Apple und Podcast Index, zeigt Treffer beider und
    /// jeden Podcast nur einmal, auch wenn beide ihn kennen.
    @MainActor func testSearchMergesBothSources() {
        let app = openAddSheet()
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("kaffee")
        XCTAssertTrue(subscribeButtons(app, for: "Code und Kaffee").firstMatch.waitForExistence(timeout: 10),
                      "Kein Treffer aus der Suche")
        XCTAssertEqual(subscribeButtons(app, for: "Code und Kaffee").count, 1,
                       "Ein Podcast, den beide Dienste kennen, steht doppelt da")
        XCTAssertEqual(subscribeButtons(app, for: "Kaffeeklatsch").count, 1,
                       "Derselbe Feed in anderer Schreibweise steht doppelt da")
        XCTAssertTrue(subscribeButtons(app, for: "Bohnenfunk").firstMatch.exists,
                      "Der Treffer, den nur Podcast Index kennt, fehlt")
        XCTAssertFalse(subscribeButtons(app, for: "Kaffee ohne Feed").firstMatch.exists,
                       "Ein Treffer ohne Feed steht in der Liste")
        attach(app, "katalog-suche")
    }
}
