//
//  PodcastCatalog.swift
//  PodcastAI
//
//  Der Katalog im Blatt „Podcast hinzufügen“: Charts und Kategorien aus
//  Apple Podcasts, gesucht wird bei Apple und bei Podcast Index zugleich.
//  Kein Schlüssel, kein Konto, der Katalog ist immer an.
//
//  Das Land der Charts kommt aus der Region des Geräts, siehe
//  `CatalogStorefront`.
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

    /// Podcast Index, dort sucht die App zusätzlich.
    static let podcastIndexWebsite = URL(string: "https://podcastindex.org")!
    /// Datenschutzerklärung von Podcast Index.
    static let podcastIndexPrivacyPolicy = URL(string: "https://github.com/Podcastindex-org/legal/blob/main/PrivacyPolicy.md")!

    private let client: PodcastCatalogClient
    /// Feste Antworten statt Netz, nur für UI-Tests.
    private let usesFixtures: Bool

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-catalog-fixtures") {
            client = PodcastCatalogClient(country: "de", userAgent: Self.userAgent,
                                          transport: CatalogFixtures.transport)
            usesFixtures = true
            return
        }
        #endif
        client = PodcastCatalogClient(userAgent: Self.userAgent)
        usesFixtures = false
    }

    /// `PodcastAI/0.7.2`: Podcast Index verlangt einen User-Agent, der die
    /// App nennt, und lehnt allgemeine ab.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "PodcastAI/\(version)"
    }

    /// Cover kommen über `ArtworkImage` und damit über den gemeinsamen
    /// `URLCache`. Etwas größer als ab Werk, damit Katalog und Mediathek
    /// Bilder nicht dauernd neu laden.
    static func configureImageCache() {
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
    }

    /// „Deutschland“ für „de“, in der Sprache der App.
    static func regionName(_ country: String) -> String {
        Locale(identifier: AppLanguage.current.rawValue).localizedString(forRegionCode: country.uppercased())
            ?? country.uppercased()
    }

    // MARK: - Suche, Charts

    /// Sucht bei Apple und bei Podcast Index zugleich und führt die Treffer
    /// zusammen.
    func search(_ term: String) async throws -> [CatalogPodcast] {
        try await client.search(term)
    }

    /// Sucht nur im Apple-Podcast-Verzeichnis.
    func searchApple(_ term: String) async throws -> [CatalogPodcast] {
        try await client.searchApple(term)
    }

    /// Eine Seite der Charts. Charts und Einzelheiten hält der Client eine
    /// Viertelstunde.
    func page(of chart: CatalogChart, offset: Int, count: Int) async throws -> CatalogPage {
        try await client.page(of: chart, offset: offset, count: count)
    }

    // MARK: - Seite eines Podcasts

    /// Beschreibung, Website und neueste Folgen aus dem Feed des Podcasts.
    /// Über `AppModel`, damit ein Abo gleich danach den Feed nicht noch
    /// einmal lädt. In UI-Tests aus einem festen Feed.
    func preview(of feed: URL, model: AppModel) async throws -> PodcastPreview {
        #if DEBUG
        if usesFixtures {
            guard let data = CatalogFixtures.feed(for: feed) else { throw CatalogError.unreadableAnswer }
            return PodcastPreview(try FeedParser().parse(data), feedURL: feed)
        }
        #endif
        return try await model.previewPodcast(feed)
    }
}
