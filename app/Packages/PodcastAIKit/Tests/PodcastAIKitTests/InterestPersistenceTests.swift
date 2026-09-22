import Testing
import Foundation
@testable import PodcastAIKit

@Suite("Interessen speichern")
struct InterestPersistenceTests {

    @Test("Ein angelegtes Thema erscheint wieder im Profil")
    func topicRoundTrip() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(interest: Interest(label: "Neue KI Modelle", kind: .topic, origin: .confirmedByUser))
        let profile = try await store.interestProfile(learningEnabled: false)
        #expect(profile.topics.map(\.label) == ["Neue KI Modelle"])
    }
}

@Suite("Beta-Feedback 0.1")
struct BetaFeedbackTests {

    @Test("Ein MP3-Link mit Zähler in der Abfrage ist eine Folge, kein Feed und keine Webseite")
    func mp3LinkIsAudio() throws {
        let link = try SourceResolver().resolve(
            "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=webplayer-download")
        guard case .audioFile = link else { Issue.record("aufgelöst als \(link)"); return }
    }

    @Test("Eine Podigee-Seite verweist im Kopf auf ihren Feed")
    func podigeeFeedLink() {
        let html = #"<head><link rel="alternate" type="application/rss+xml" title="Think AI" href="https://think-ai.podigee.io/feed/mp3"></head>"#
        let links = FeedDiscovery.feedLinks(inHTML: html, base: URL(string: "https://think-ai.podigee.io/")!)
        #expect(links.first?.absoluteString == "https://think-ai.podigee.io/feed/mp3")
    }
}
