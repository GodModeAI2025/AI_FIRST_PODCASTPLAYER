//
//  YouTubeTakeoutTests.swift
//  PodcastAIKitTests
//
//  YouTube-Abos aus Google Takeout: die CSV-Datei lesen, wie Google sie
//  schreibt und wie Tabellenprogramme sie wieder speichern, passende
//  Audio-Podcasts ordnen und die Liste zum Abhaken führen.
//  Kein Test geht ins Netz.
//

import Foundation
import Testing
import PodcastAIKit
@testable import PodcastAISources

private let lage = "UCaaaaaaaaaaaaaaaaaaaaa1"
private let kurz = "UCbbbbbbbbbbbbbbbbbbbbb2"
private let werk = "UCccccccccccccccccccccc3"

private func channels(_ text: String) throws -> [TakeoutChannel] {
    try YouTubeTakeout.channels(in: Data(text.utf8))
}

@Suite("Google Takeout: subscriptions.csv lesen")
struct TakeoutCSVTests {

    @Test("Englische Kopfzeile, BOM, Anführungszeichen, Kommas und leere Zeilen")
    func readsTypicalExport() throws {
        let csv = "\u{FEFF}Channel Id,Channel Url,Channel Title\n"
            + "\(lage),http://www.youtube.com/channel/\(lage),Lage der Nation\n"
            + "\n"
            + "\(kurz),http://www.youtube.com/channel/\(kurz),\"Kurz, knapp und \"\"klar\"\"\"\n"
            + "   \n"
            + "\(werk),http://www.youtube.com/channel/\(werk),\"Werkstatt\nam Abend\"\n"
            + "\n"
        let found = try channels(csv)
        #expect(found.map(\.channelID) == [lage, kurz, werk])
        #expect(found[0].title == "Lage der Nation")
        #expect(found[1].title == "Kurz, knapp und \"klar\"")
        // Ein Umbruch im Namen wird zum Leerzeichen.
        #expect(found[2].title == "Werkstatt am Abend")
        #expect(found[0].channelURL.absoluteString == "https://www.youtube.com/channel/\(lage)")
        #expect(found[0].feedURL.absoluteString == "https://www.youtube.com/feeds/videos.xml?channel_id=\(lage)")
    }

    @Test("CRLF, deutsche Kopfzeile in anderer Reihenfolge")
    func readsGermanHeaderAndCRLF() throws {
        let csv = "Kanaltitel,Kanal-ID,Kanal-URL\r\n"
            + "Lage der Nation,\(lage),http://www.youtube.com/channel/\(lage)\r\n"
            + "\r\n"
            + "Kurz erklärt,\(kurz),http://www.youtube.com/channel/\(kurz)\r\n"
        let found = try channels(csv)
        #expect(found.map(\.channelID) == [lage, kurz])
        #expect(found.map(\.title) == ["Lage der Nation", "Kurz erklärt"])
    }

    @Test("Nur CR als Zeilenende")
    func readsClassicMacLineEndings() throws {
        let csv = "Channel Id,Channel Url,Channel Title\r\(lage),,Lage\r\(kurz),,Kurz\r"
        #expect(try channels(csv).map(\.channelID) == [lage, kurz])
    }

    @Test("Semikolon aus einer Tabellenkalkulation, Kopfzeile in fremder Sprache")
    func detectsColumnsByContent() throws {
        let csv = "ID des chaînes;URL des chaînes;Titres des chaînes\n"
            + "\(lage);http://www.youtube.com/channel/\(lage);Lage; der Nation\n"
            + "\(kurz);http://www.youtube.com/channel/\(kurz);\"Kurz; erklärt\"\n"
        let found = try channels(csv)
        #expect(found.map(\.channelID) == [lage, kurz])
        // Ein Semikolon ohne Anführungszeichen trennt, der Rest ist eine eigene Spalte.
        #expect(found[0].title == "Lage")
        #expect(found[1].title == "Kurz; erklärt")
    }

    @Test("Ohne Kopfzeile, Kennung nur in der Adresse, doppelte Kanäle")
    func readsWithoutHeaderAndFromURL() throws {
        let csv = "\(lage),http://www.youtube.com/channel/\(lage),Lage\n"
            + ",https://www.youtube.com/channel/\(kurz),Kurz\n"
            + "\(lage),http://www.youtube.com/channel/\(lage),Lage doppelt\n"
            + "keine-kennung,https://www.youtube.com/@irgendwer,Fremd\n"
        let found = try channels(csv)
        #expect(found.map(\.channelID) == [lage, kurz])
        #expect(found.map(\.title) == ["Lage", "Kurz"])
    }

    @Test("UTF-16 mit BOM und Windows-1252")
    func readsOtherEncodings() throws {
        let csv = "Channel Id,Channel Url,Channel Title\n\(lage),,Grüße aus Köln\n"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(csv.data(using: .utf16LittleEndian)!)
        #expect(try YouTubeTakeout.channels(in: utf16).first?.title == "Grüße aus Köln")
        let latin = csv.data(using: .windowsCP1252)!
        #expect(try YouTubeTakeout.channels(in: latin).first?.title == "Grüße aus Köln")
    }

    @Test("Ohne Namen zeigt die Liste die Kennung")
    func fallsBackToIDWithoutTitle() throws {
        let found = try channels("Channel Id,Channel Url,Channel Title\n\(lage),,\n")
        #expect(found.first?.title == "")
        #expect(found.first?.displayTitle == lage)
    }

    @Test("Andere Dateien sind keine Abo-Liste")
    func rejectsOtherFiles() {
        #expect(throws: TakeoutImportError.notTakeout) { try channels("Name,Adresse\nMax,Berlin\n") }
        #expect(throws: TakeoutImportError.notTakeout) {
            try channels(#"<?xml version="1.0"?><opml version="2.0"></opml>"#)
        }
        #expect(throws: TakeoutImportError.noChannels) { try channels("") }
        #expect(throws: TakeoutImportError.noChannels) { try channels("\u{FEFF}\n\n") }
        #expect(throws: TakeoutImportError.noChannels) { try channels("Channel Id,Channel Url,Channel Title\n") }
        let huge = Data(count: YouTubeTakeout.maximumBytes + 1)
        #expect(throws: TakeoutImportError.tooLarge) { try YouTubeTakeout.channels(in: huge) }
    }

    @Test("Felder: Anführungszeichen mitten im Feld bleiben, leere Felder zählen")
    func splitsFields() {
        let records = YouTubeTakeout.records(in: "a,\"b,c\",d\"e,,\"\"\n\n\"x\"\"y\"\r\nz")
        #expect(records == [["a", "b,c", "d\"e", "", ""], ["x\"y"], ["z"]])
    }
}

@Suite("Google Takeout: passender Audio-Podcast")
struct TakeoutCounterpartTests {

    private func podcast(_ title: String, _ author: String, _ feed: String) -> CatalogPodcast {
        CatalogPodcast(origin: .appleDirectory, title: title, author: author,
                       feedURL: URL(string: "https://example.com/\(feed)")!)
    }

    @Test("Gleicher Titel vor gleichem Autor vor Titel mit dem Namen")
    func ranksExactMatchesFirst() {
        let results = [
            podcast("Das Beste aus Lage der Nation", "Radio Beispiel", "a"),
            podcast("Politik am Morgen", "Lage der Nation", "b"),
            podcast("Lage der Nation", "Philip Banse & Ulf Buermeyer", "c"),
            podcast("Lage der Nation", "Doppelt", "c/"),
            podcast("Nationalpark", "Lage", "d"),
        ]
        let ranked = ChannelCounterpartRanking.ranked(results, forChannel: "Lage der Nation")
        #expect(ranked.map(\.feedURL.lastPathComponent) == ["c", "b", "a"])
    }

    @Test("Nur ganze Wörter, Akzente und Satzzeichen egal, kurze Namen gar nicht")
    func matchesWordsOnly() {
        let results = [
            podcast("National Geographic", "Nat Geo", "a"),
            podcast("Café Élysée – Der Podcast", "Studio", "b"),
            podcast("LinusTechTips", "Linus Media Group", "c"),
        ]
        #expect(ChannelCounterpartRanking.ranked(results, forChannel: "Nati").isEmpty)
        #expect(ChannelCounterpartRanking.ranked(results, forChannel: "cafe elysee").map(\.feedURL.lastPathComponent) == ["b"])
        #expect(ChannelCounterpartRanking.ranked(results, forChannel: "Linus Tech Tips").map(\.feedURL.lastPathComponent) == ["c"])
        #expect(ChannelCounterpartRanking.ranked(results, forChannel: "Nat").map(\.feedURL.lastPathComponent) == ["a"])
        #expect(ChannelCounterpartRanking.ranked(results, forChannel: "Ab").isEmpty)
        #expect(!ChannelCounterpartRanking.isSearchable(" – "))
    }

    @Test("Höchstens drei Möglichkeiten")
    func limitsCandidates() {
        let results = (0..<6).map { podcast("Kanal \($0)", "Kanal", "\($0)") }
        #expect(ChannelCounterpartRanking.ranked(results, forChannel: "Kanal").count == 3)
    }

    @Test("Tempo: erst zügig, dann alle drei Sekunden, nach 403 eine Minute Pause")
    func pacesDirectorySearches() {
        var pace = DirectorySearchPace(burst: 2, quickInterval: 0.25, interval: 3, coolDown: 60)
        var now = Date(timeIntervalSince1970: 1_790_140_000)
        #expect(pace.delay(before: now) == 0)
        now += 0.1
        #expect(abs(pace.delay(before: now) - 0.15) < 0.001)
        now += 1
        // Die schnelle Portion ist verbraucht: drei Sekunden nach dem letzten Start.
        #expect(abs(pace.delay(before: now) - 2.15) < 0.001)
        now += 6
        #expect(pace.delay(before: now) == 0)
        pace.noteRateLimited(at: now)
        #expect(abs(pace.delay(before: now + 1) - 59) < 0.001)
    }
}

@Suite("Google Takeout: Liste zum Abhaken")
struct TakeoutSelectionTests {

    private let channelList = [
        TakeoutChannel(channelID: lage, title: "Lage der Nation")!,
        TakeoutChannel(channelID: kurz, title: "Kurz erklärt")!,
        TakeoutChannel(channelID: werk, title: "Werkstatt")!,
    ]
    private let lagePodcast = CatalogPodcast(origin: .appleDirectory, title: "Lage der Nation",
                                             author: "Philip Banse", feedURL: URL(string: "https://example.com/lage.xml")!)
    private let kurzPodcast = CatalogPodcast(origin: .appleDirectory, title: "Kurz erklärt",
                                             author: "Beispiel", feedURL: URL(string: "https://example.com/kurz.xml")!)

    @Test("Gefundene Audio-Podcasts werden vorgeschlagen und ausgewählt, bis jemand selbst wählt")
    func recommendsAudioPodcasts() {
        var selection = TakeoutImportSelection(channels: channelList, subscribedFeeds: [])
        #expect(selection.pendingIDs == [lage, kurz, werk])
        selection.recordResults([lagePodcast], for: lage)
        #expect(selection.selected == [lage])
        #expect(selection.target(for: lage) == .audioPodcast(lagePodcast.feedURL))
        selection.recordResults([], for: werk)
        #expect(selection.lookups[werk] == .nothing)
        #expect(selection.target(for: werk) == .youTubeChannel)
        #expect(!selection.selected.contains(werk))
        // Ab der ersten eigenen Wahl wählt das Modell nichts mehr von selbst.
        selection.toggle(werk)
        selection.recordResults([kurzPodcast], for: kurz)
        #expect(selection.selected == [lage, werk])
        #expect(selection.lookupDoneCount == 3)
        #expect(selection.recommendedIDs == [lage, kurz])
    }

    @Test("Kanal statt Audio-Podcast, Auswahl über alle")
    func choosesTargets() {
        var selection = TakeoutImportSelection(channels: channelList, subscribedFeeds: [])
        selection.recordResults([lagePodcast], for: lage)
        selection.recordResults([], for: kurz)
        selection.recordFailure(for: werk)
        selection.choose(.youTubeChannel, for: lage)
        #expect(selection.target(for: lage) == .youTubeChannel)
        // Ein Podcast, den die Suche nicht vorgeschlagen hat, lässt sich nicht wählen.
        selection.choose(.audioPodcast(kurzPodcast.feedURL), for: kurz)
        #expect(selection.target(for: kurz) == .youTubeChannel)
        #expect(!selection.selected.contains(kurz))
        selection.selectAll()
        #expect(selection.selected == [lage, kurz, werk])
        #expect(selection.subscriptions.map(\.feedURL) == channelList.map(\.feedURL))
        #expect(selection.subscriptions.allSatisfy { !$0.isAudioPodcast })
        selection.selectRecommended()
        #expect(selection.selected == [lage])
        selection.deselectAll()
        #expect(selection.subscriptions.isEmpty)
    }

    @Test("Schon Abonniertes bietet die Liste nicht noch einmal an")
    func skipsSubscribedFeeds() {
        // Der Audio-Podcast unter einer anderen Schreibweise, der Kanal mit seinem Feed.
        var selection = TakeoutImportSelection(
            channels: channelList,
            subscribedFeeds: [URL(string: "http://www.example.com/lage.xml/")!, channelList[1].feedURL])
        selection.recordResults([lagePodcast], for: lage)
        selection.recordResults([], for: kurz)
        #expect(selection.isAudioSubscribed(lage))
        #expect(!selection.hasRecommendation(lage))
        #expect(selection.availableTargets(for: lage) == [.youTubeChannel])
        #expect(selection.isChannelSubscribed(kurz))
        #expect(!selection.isSelectable(kurz))
        selection.toggle(kurz)
        #expect(!selection.selected.contains(kurz))
        selection.selectAll()
        #expect(selection.selected == [lage, werk])

        // Nach dem Abonnieren fällt der Kanal aus der Auswahl.
        selection.updateSubscribedFeeds([lagePodcast.feedURL, channelList[1].feedURL, channelList[0].feedURL])
        #expect(selection.selected == [werk])
    }

    @Test("Zwei Kanäle, ein Audio-Podcast: einmal abonniert")
    func deduplicatesSubscriptions() {
        let twins = [
            TakeoutChannel(channelID: lage, title: "Lage der Nation")!,
            TakeoutChannel(channelID: kurz, title: "Philip Banse")!,
        ]
        var selection = TakeoutImportSelection(channels: twins, subscribedFeeds: [])
        selection.recordResults([lagePodcast], for: lage)
        selection.recordResults([lagePodcast], for: kurz)
        #expect(selection.selected == [lage, kurz])
        let plan = selection.subscriptions
        #expect(plan.count == 1)
        #expect(plan.first?.channelIDs == [lage, kurz])
        #expect(plan.first?.title == "Lage der Nation")
        #expect(plan.first?.isAudioPodcast == true)
    }

    @Test("Suche beenden und noch einmal suchen")
    func stopsAndRetriesLookups() {
        var selection = TakeoutImportSelection(channels: channelList, subscribedFeeds: [])
        selection.recordFailure(for: lage)
        selection.skipRemainingLookups()
        #expect(selection.pendingIDs.isEmpty)
        #expect(selection.lookups[kurz] == .skipped)
        // Ohne Ergebnis bleibt der Kanal selbst.
        #expect(selection.target(for: kurz) == .youTubeChannel)
        selection.retryUnfinishedLookups()
        #expect(selection.pendingIDs == [lage, kurz, werk])
    }
}
