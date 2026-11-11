//
//  PlayerFeedCacheTests.swift
//  PodcastAIKitTests
//
//  Uhr und Fernseher fragen bei jedem Feed beim Server nach und halten ihn
//  auf der Platte, damit die Antwort 304 heißen kann. Geht ein Abo, geht der
//  Cache mit. Sonst darf ihn nichts leeren: `reload()` läuft nach jedem
//  geladenen Feed, und ein Leeren dort ließe den Cache nie voll werden.
//
//  Ohne Netz und ohne Platte: geprüft wird die Einstellung der Session, und
//  das Leeren zählt ein eigener Cache.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIPlayerKit
import PodcastAICore

/// Zählt, wie oft geleert wird, statt etwas zu tun.
private final class CountingCache: URLCache, @unchecked Sendable {
    var cleared = 0
    override func removeAllCachedResponses() { cleared += 1 }
}

@Suite("Player: Feeds im Cache")
@MainActor
struct PlayerFeedCacheTests {

    private func source(_ id: String) -> Source {
        Source(id: SourceID(rawValue: id), kind: .podcastRSS, title: id,
               feedURL: URL(string: "https://example.com/\(id).xml"))
    }

    @Test("Die Feed-Session fragt immer nach und legt auf der Platte ab")
    func sessionRevalidatesIntoTheDiskCache() throws {
        let library = PlayerLibrary(
            container: try PlayerLibrary.makeContainer(storeURL: nil, sync: false),
            storage: .temporary, deviceID: "watch-1")
        defer { library.session.invalidateAndCancel() }
        let configuration = library.session.configuration
        #expect(configuration.requestCachePolicy == .reloadRevalidatingCacheData)
        #expect(configuration.urlCache === PlayerLibrary.feedCache)
        // `URLCache` nimmt Antworten bis 5 % der Kapazität. Der größte Feed,
        // den der Player lädt, muss hineinpassen.
        #expect(PlayerLibrary.feedCache.diskCapacity / 20 >= Int(library.feedByteLimit))
    }

    @Test("Geht ein Abo, wird der Cache geleert, und nur dann")
    func cacheIsClearedOnlyWhenAShowDisappears() throws {
        let container = try PlayerLibrary.makeContainer(storeURL: nil, sync: false)
        let library = PlayerLibrary(container: container, storage: .temporary, deviceID: "watch-1")
        let cache = CountingCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
        library.session = SafeHTTP.makeSession { $0.urlCache = cache }
        defer { library.session.invalidateAndCancel() }

        library.insertForTesting(source: source("a"))
        library.insertForTesting(source: source("b"))
        library.reload()
        // So sieht es nach jedem geladenen Feed aus: nichts ändert sich, oder
        // ein Abo ist dazugekommen.
        library.reload()
        library.insertForTesting(source: source("c"))
        library.reload()
        #expect(cache.cleared == 0)

        // Ein Abgleich über iCloud bringt beides auf einmal: „a“ geht, „d“
        // kommt. Die Zahl der Abos bleibt gleich, geleert wird trotzdem.
        let rows = try container.mainContext.fetch(FetchDescriptor<StoredSource>())
        let gone = try #require(rows.first { $0.identifier == "a" })
        gone.isSubscribed = false
        try container.mainContext.save()
        library.insertForTesting(source: source("d"))
        library.reload()
        #expect(library.shows.map(\.id.rawValue) == ["b", "c", "d"])
        #expect(cache.cleared == 1)

        // Danach ist wieder Ruhe.
        library.reload()
        #expect(cache.cleared == 1)
    }
}
