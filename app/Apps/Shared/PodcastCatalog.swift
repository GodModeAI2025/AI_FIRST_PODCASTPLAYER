//
//  PodcastCatalog.swift
//  PodcastAI
//
//  Der Katalog im Blatt „Podcast hinzufügen“: Suche, Trends und Rubriken
//  über Podcast Index, dazu das Apple-Podcast-Verzeichnis wie bisher.
//
//  Der Zugang liegt in `Config/PodcastIndex/PodcastIndexCredentials.plist`,
//  die nicht im Repository steht und beim Bauen in das App-Bundle kommt.
//  Fehlt sie oder ist ein Feld leer, ist der Katalog aus: die Suche fragt
//  nur Apple, Trends und Rubriken bleiben verborgen.
//
//  Was der Katalog liefert, ist fremder Text. Er wird angezeigt und sonst
//  nirgends hingegeben, auch keinem Sprachmodell. Abgespielt wird aus dem
//  Katalog nichts.
//

import Foundation
import PodcastAIKit

@MainActor
final class PodcastCatalog {

    static let shared = PodcastCatalog()

    /// Die Seite, auf die „Katalog: Podcast Index“ verweist.
    static let website = URL(string: "https://podcastindex.org")!
    /// Datenschutzerklärung von Podcast Index.
    static let privacyPolicy = URL(string: "https://github.com/Podcastindex-org/legal/blob/main/PrivacyPolicy.md")!

    private let client: PodcastIndexClient?
    /// Feste Antworten statt Netz, nur für UI-Tests.
    private let usesFixtures: Bool
    /// Was jemand angesehen hat, für eine Viertelstunde. Die Betreiber
    /// bitten darum, die API zu schonen, und erlauben das Zwischenspeichern
    /// dessen, was ein Nutzer öffnet.
    private var cache: [String: (at: Date, value: Any)] = [:]
    private static let cacheLifetime: TimeInterval = 15 * 60

    /// Trends, Rubriken und Einzelheiten gibt es nur mit Zugang.
    var isAvailable: Bool { client != nil }

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-catalog-fixtures") {
            client = PodcastIndexClient(credentials: PodcastIndexFixtures.credentials,
                                        userAgent: Self.userAgent, transport: PodcastIndexFixtures.transport)
            usesFixtures = true
            return
        }
        #endif
        usesFixtures = false
        if let credentials = Self.bundledCredentials(), credentials.isComplete {
            client = PodcastIndexClient(credentials: credentials, userAgent: Self.userAgent)
        } else {
            client = nil
        }
    }

    /// `PodcastAI/0.7.2`: so erkennt der Betreiber die App in seinen Protokollen.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "PodcastAI/\(version)"
    }

    private static func bundledCredentials() -> PodcastIndexCredentials? {
        guard let url = Bundle.main.url(forResource: "PodcastIndexCredentials", withExtension: "plist",
                                        subdirectory: "PodcastIndex"),
              let data = try? Data(contentsOf: url) else { return nil }
        return PodcastIndexCredentials(propertyList: data)
    }

    /// Cover kommen über `AsyncImage` und damit über den gemeinsamen
    /// `URLCache`. Etwas größer als ab Werk, damit Katalog und Mediathek
    /// Bilder nicht dauernd neu laden.
    static func configureImageCache() {
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
    }

    // MARK: - Suche

    /// Sucht in Podcast Index und im Apple-Verzeichnis zugleich und führt
    /// die Treffer zusammen. Antwortet nur eines von beiden, zählt dessen
    /// Liste. Ohne Zugang zum Katalog sucht nur Apple, wie bisher.
    func search(_ term: String) async throws -> [CatalogPodcast] {
        guard let client else { return try await PodcastDirectory.search(term) }
        if usesFixtures { return try await client.search(term) }
        async let index = Self.outcome { try await client.search(term) }
        async let apple = Self.outcome { try await PodcastDirectory.search(term) }
        let (fromIndex, fromApple) = await (index, apple)
        try Task.checkCancellation()
        switch (fromIndex, fromApple) {
        case (.success(let found), .success(let listed)):
            return CatalogMerge.merged(found, listed)
        case (.success(let found), .failure):
            return found
        case (.failure, .success(let listed)):
            return listed
        case (.failure, .failure(let error)):
            // Die Meldung des Apple-Verzeichnisses kennt man schon.
            throw error
        }
    }

    // MARK: - Trends, Einzelheiten, Folgen

    func trending(language: AppLanguage?, category: CatalogCategory? = nil, max: Int) async throws -> [CatalogPodcast] {
        guard let client else { throw PodcastIndexError.missingCredentials }
        let key = "trending|\(language?.rawValue ?? "*")|\(category?.rawValue ?? "*")|\(max)"
        if let cached: [CatalogPodcast] = cached(key) { return cached }
        let podcasts = try await client.trending(language: language, category: category, max: max)
        store(podcasts, for: key)
        return podcasts
    }

    func podcast(id: Int) async throws -> CatalogPodcast {
        guard let client else { throw PodcastIndexError.missingCredentials }
        let key = "podcast|\(id)"
        if let cached: CatalogPodcast = cached(key) { return cached }
        let podcast = try await client.podcast(id: id)
        store(podcast, for: key)
        return podcast
    }

    func episodes(feedID: Int) async throws -> [CatalogEpisode] {
        guard let client else { throw PodcastIndexError.missingCredentials }
        let key = "episodes|\(feedID)"
        if let cached: [CatalogEpisode] = cached(key) { return cached }
        let episodes = try await client.episodes(feedID: feedID, max: 10)
        store(episodes, for: key)
        return episodes
    }

    // MARK: - Zwischenspeicher

    private func cached<Value>(_ key: String) -> Value? {
        guard let entry = cache[key], Date().timeIntervalSince(entry.at) < Self.cacheLifetime else { return nil }
        return entry.value as? Value
    }

    private func store(_ value: Any, for key: String) {
        cache[key] = (Date(), value)
    }

    private nonisolated static func outcome<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
