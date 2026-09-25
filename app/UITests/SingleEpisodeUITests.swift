//
//  SingleEpisodeUITests.swift
//  PodcastAIUITests
//
//  „Nur diese Folge“ und „Nur dieses Video“: eine Folge holen, ohne den
//  Podcast zu abonnieren. Sie steht danach unter ihrem Podcast, der als
//  „nicht abonniert“ gekennzeichnet ist und sich mit einem Tipp abonnieren
//  lässt.
//
//  Der erste Test läuft mit `-catalog-fixtures` ohne Netz. Die beiden
//  anderen fragen Apple und YouTube wie die übrigen Link-Tests.
//

import XCTest

final class SingleEpisodeUITests: XCTestCase {

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

    @MainActor private func openAddSheet(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-fresh"] + arguments
        app.launch()
        tab(app, "Meine Podcasts")
        app.navigationBars.buttons["Podcast hinzufügen"].firstMatch.tap()
        return app
    }

    @MainActor private func paste(_ link: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(link)
        app.buttons["source.addLink"].tap()
    }

    /// Nach dem Holen: das Blatt schließen und prüfen, dass der Podcast als
    /// „nicht abonniert“ dasteht und sich abonnieren lässt.
    @MainActor private func expectNotSubscribed(_ app: XCUIApplication, title: String) {
        // Zurück aus der Vorschau, dann schließt „Fertig“ das Blatt.
        let back = app.navigationBars.buttons["Hinzufügen"].firstMatch
        if back.exists { back.tap() }
        let done = app.navigationBars.buttons["Fertig"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "„Fertig“ fehlt nach dem Holen")
        done.tap()
        let badge = app.descendants(matching: .any)["source.notSubscribed"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "Der Podcast steht nicht als „nicht abonniert“ da")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.exists, "Die Folge liegt nicht unter ihrem Podcast")
        attach(app, "nicht-abonniert")
        row.tap()
        XCTAssertTrue(app.buttons["source.subscribe"].waitForExistence(timeout: 10),
                      "In der Folgenliste fehlt „Abonnieren“")
    }

    /// Katalog: auf der Seite eines Podcasts eine einzelne Folge holen.
    @MainActor func testJustThisEpisodeFromCatalog() {
        let app = openAddSheet(["-catalog-fixtures", "-automaticAnalysis", "NO"])
        let field = app.descendants(matching: .any)["source.input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("kaffee")
        let row = app.buttons.matching(identifier: "catalog.row")
            .matching(NSPredicate(format: "label CONTAINS 'Code und Kaffee'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Kein Treffer aus der Suche")
        row.tap()

        let single = app.buttons["episode.single"].firstMatch
        var attempts = 6
        while !(single.exists && single.isHittable) && attempts > 0 {
            app.swipeUp()
            attempts -= 1
        }
        XCTAssertTrue(single.exists, "Neben den Folgen fehlt „Nur diese Folge“")
        single.tap()
        let done = app.descendants(matching: .any)["episode.single.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Die Folge wurde nicht geholt")
        attach(app, "katalog-einzelne-folge")
        expectNotSubscribed(app, title: "Code und Kaffee")
    }

    /// Die Kennung der neuesten Folge eines Podcasts im Apple-Verzeichnis.
    nonisolated static func newestEpisodeID(ofPodcast podcastID: Int) -> Int? {
        guard let url = URL(string:
            "https://itunes.apple.com/lookup?id=\(podcastID)&entity=podcastEpisode&limit=1") else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found: Int?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return }
            found = results.first { ($0["kind"] as? String) == "podcast-episode" }?["trackId"] as? Int
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return found
    }

    /// Apple Podcasts mit `?i=`: Vorschau mit der Folge, „Nur diese Folge“
    /// und „Abonnieren“.
    @MainActor func testAppleEpisodeLinkOffersJustThisEpisode() throws {
        // Eine feste Folgenkennung veraltet: Apple nennt im Lookup nur die
        // jüngeren Folgen. Deshalb die neueste Folge zur Laufzeit holen.
        let episodeID = try XCTUnwrap(Self.newestEpisodeID(ofPodcast: 1200361736),
                                      "Apple-Verzeichnis nicht erreichbar")
        let app = openAddSheet(["-automaticAnalysis", "NO", "-keepNewestAudio", "NO"])
        paste("https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=\(episodeID)", in: app)
        let single = app.buttons["link.single"]
        XCTAssertTrue(single.waitForExistence(timeout: 45), "Keine Vorschau zur Folge aus Apple Podcasts")
        XCTAssertTrue(app.buttons["link.subscribe"].exists, "Neben „Nur diese Folge“ fehlt „Abonnieren“")
        attach(app, "apple-folge")
        single.tap()
        XCTAssertTrue(app.descendants(matching: .any)["link.single.done"].waitForExistence(timeout: 30))
        expectNotSubscribed(app, title: "The Daily")
    }

    /// Ein YouTube-Video: Vorschau des Kanals mit „Kanal abonnieren“ und
    /// „Nur dieses Video“, der Audio-Podcast steht, falls es ihn gibt, zuerst.
    @MainActor func testYouTubeVideoLinkOffersChoices() {
        let app = openAddSheet([])
        paste("https://youtu.be/pOX1l1edBME?si=uitest", in: app)
        let channel = app.buttons["youtube.subscribeChannel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 45), "Keine Vorschau zum YouTube-Video")
        let video = app.buttons["youtube.singleVideo"]
        XCTAssertTrue(video.exists, "„Nur dieses Video“ fehlt")
        let counterpart = app.buttons["youtube.subscribeCounterpart"].firstMatch
        if counterpart.exists {
            XCTAssertLessThan(counterpart.frame.minY, channel.frame.minY,
                              "Der Audio-Podcast steht nicht vor dem Kanal")
        }
        attach(app, "youtube-vorschau")
        video.tap()
        XCTAssertTrue(app.descendants(matching: .any)["youtube.singleVideo.done"].waitForExistence(timeout: 30))
        expectNotSubscribed(app, title: "Marques Brownlee")
    }
}
