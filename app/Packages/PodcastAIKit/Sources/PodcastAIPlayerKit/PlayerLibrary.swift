//
//  PlayerLibrary.swift
//  PodcastAIPlayerKit
//
//  Die Bibliothek eines Players: Abos, Folgen, Fortsetzungsstelle.
//
//  Gelesen wird, was iPhone, iPad und Mac über iCloud abgleichen. Geschrieben
//  wird so wenig wie möglich:
//
//  - Die eigene Zeile des Hörzustands (`StoredListeningState`) für die
//    Fortsetzungsstelle, nie die Zeile eines anderen Geräts.
//  - Quellen und Folgen nur im lokalen Betrieb ohne Abgleich. Mit Abgleich
//    liest der Player sie nur; frische Folgen aus dem Feed liegen im
//    Speicher (Überlagerung), damit in iCloud kein zweiter Satz Folgen
//    entsteht, den das iPhone erst wieder bereinigen müsste.
//
//  Gelöscht wird nie etwas. Eine Folge zu löschen ist Sache der iOS-App und
//  räumt dort alles auf, was aus ihr entstanden ist.
//

#if canImport(SwiftData)
import Foundation
import CoreData
import SwiftData
import Observation
import PodcastAICore

@MainActor
@Observable
public final class PlayerLibrary {

    public enum Storage: Sendable, Equatable {
        /// Mit iCloud-Abgleich.
        case synced
        /// Ohne Abgleich, die Daten bleiben auf diesem Gerät.
        case localOnly
        /// Nur im Arbeitsspeicher, nichts bleibt.
        case temporary
    }

    public let storage: Storage
    /// Kennung dieses Geräts im Schlüssel der Hörzustandszeile.
    public let deviceID: String

    /// Abonnierte Podcasts, nach Titel sortiert.
    public private(set) var shows: [Source] = []
    /// Die neuesten Folgen aller Abos.
    public private(set) var latest: [PlayerItem] = []
    /// Wird mit jeder Änderung durch iCloud größer.
    public private(set) var changeCount = 0
    public private(set) var isRefreshing = false

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var overlay: [SourceID: [Episode]] = [:]
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private lazy var session = SafeHTTP.makeSession()

    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer, storage: Storage, deviceID: String) {
        self.container = container
        self.storage = storage
        self.deviceID = deviceID
    }

    deinit { observation?.cancel() }

    // MARK: - Öffnen

    nonisolated static var schema: Schema {
        Schema([StoredSource.self, StoredEpisode.self, StoredListeningState.self])
    }

    /// Baut den Container. Ohne `storeURL` liegt er im Arbeitsspeicher.
    public nonisolated static func makeContainer(storeURL: URL?, sync: Bool) throws -> ModelContainer {
        guard let storeURL else {
            let configuration = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            schema: schema, url: storeURL, cloudKitDatabase: sync ? .automatic : .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Öffnet die Bibliothek, wenn möglich mit iCloud-Abgleich, sonst lokal,
    /// sonst im Arbeitsspeicher. Wie `AppBootstrap.openStore()` der iOS-App.
    public static func open(storeDirectory: URL, deviceID: String) -> PlayerLibrary {
        let url = storeDirectory.appending(path: "PodcastAIPlayer.store")
        if let container = try? makeContainer(storeURL: url, sync: true) {
            return PlayerLibrary(container: container, storage: .synced, deviceID: deviceID)
        }
        if let container = try? makeContainer(storeURL: url, sync: false) {
            return PlayerLibrary(container: container, storage: .localOnly, deviceID: deviceID)
        }
        // Der Arbeitsspeicher geht immer.
        // swiftlint:disable:next force_try
        let container = try! makeContainer(storeURL: nil, sync: false)
        return PlayerLibrary(container: container, storage: .temporary, deviceID: deviceID)
    }

    /// Ein Gerät, das sich merkt, wer es ist. Die Kennung steckt im Schlüssel
    /// der eigenen Zeile und darf sich nicht ändern, sonst bliebe jede alte
    /// Zeile verwaist stehen.
    public nonisolated static func deviceIdentifier(
        prefix: String, defaults: UserDefaults = .standard
    ) -> String {
        let key = "playerDeviceIdentifier"
        if let stored = defaults.string(forKey: key), !stored.isEmpty { return stored }
        let made = prefix + "-" + UUID().uuidString.prefix(8).lowercased()
        defaults.set(made, forKey: key)
        return made
    }

    // MARK: - Lesen

    /// Lädt Abos und neueste Folgen neu.
    public func reload() {
        shows = loadShows()
        latest = loadLatest(limit: 60)
    }

    /// Startet das Mitlesen von Änderungen aus iCloud. Mehrere Aufrufe sind
    /// harmlos.
    public func observeRemoteChanges() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .NSPersistentStoreRemoteChange)
            for await _ in notifications {
                guard let self else { return }
                // Ein Abgleich schickt viele Meldungen hintereinander.
                try? await Task.sleep(for: .seconds(1))
                self.changeCount += 1
                self.reload()
            }
        }
    }

    private func loadShows() -> [Source] {
        let rows = (try? context.fetch(FetchDescriptor<StoredSource>(
            predicate: #Predicate { $0.isSubscribed && $0.identifier != "" }))) ?? []
        // CloudKit kennt keine eindeutigen Schlüssel: dieselbe Quelle kann
        // nach dem Abgleich zweier Geräte doppelt vorliegen.
        var seen: Set<String> = []
        return rows.sorted { $0.addedAt < $1.addedAt }
            .filter { seen.insert($0.identifier).inserted }
            .map(\.snapshot)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Die Folgen eines Podcasts, neueste zuerst. Gestorbene Folgen (von
    /// jemandem gelöscht) fehlen, auch wenn der Feed sie noch liefert.
    public func episodes(for show: Source, limit: Int = 200) -> [PlayerItem] {
        let sid = show.id.rawValue
        let rows = (try? context.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.removedAt == nil && $0.source?.identifier == sid },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))) ?? []
        let removed = removedEpisodeIDs(sourceIdentifier: sid)
        var merged = unique(rows.map(\.snapshot))
        let known = Set(merged.map(\.id))
        merged += (overlay[show.id] ?? []).filter { !known.contains($0.id) && !removed.contains($0.id) }
        merged.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        return merged.prefix(limit).map { item(for: $0, show: show) }
    }

    private func removedEpisodeIDs(sourceIdentifier sid: String) -> Set<EpisodeID> {
        let rows = (try? context.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.removedAt != nil && $0.source?.identifier == sid }))) ?? []
        return Set(rows.map { EpisodeID(rawValue: $0.identifier) })
    }

    private func loadLatest(limit: Int) -> [PlayerItem] {
        var descriptor = FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.removedAt == nil && $0.source?.isSubscribed == true },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.fetchLimit = limit * 2
        let rows = (try? context.fetch(descriptor)) ?? []
        var episodes = unique(rows.map(\.snapshot))
        let known = Set(episodes.map(\.id))
        for (_, live) in overlay { episodes += live.filter { !known.contains($0.id) } }
        episodes.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let byShow = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return episodes.compactMap { episode -> PlayerItem? in
            guard let show = byShow[episode.sourceID] else { return nil }
            return item(for: episode, show: show)
        }.prefix(limit).map { $0 }
    }

    /// Eine Folge je Kennung, die erste bleibt.
    private func unique(_ episodes: [Episode]) -> [Episode] {
        var seen: Set<EpisodeID> = []
        return episodes.filter { seen.insert($0.id).inserted }
    }

    /// Folgen zu gemerkten Kennungen, in der Reihenfolge der Kennungen. Was es
    /// nicht mehr gibt, fehlt.
    public func items(forIdentifiers identifiers: [String]) -> [PlayerItem] {
        guard !identifiers.isEmpty else { return [] }
        let wanted = Set(identifiers)
        let rows = (try? context.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.removedAt == nil && wanted.contains($0.identifier) }))) ?? []
        var byID: [String: PlayerItem] = [:]
        let showsByID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for episode in unique(rows.map(\.snapshot)) {
            byID[episode.id.rawValue] = item(for: episode, show: showsByID[episode.sourceID])
        }
        for (sourceID, live) in overlay {
            for episode in live where wanted.contains(episode.id.rawValue) && byID[episode.id.rawValue] == nil {
                byID[episode.id.rawValue] = item(for: episode, show: showsByID[sourceID])
            }
        }
        return identifiers.compactMap { byID[$0] }
    }

    public func item(for episode: Episode, show: Source?) -> PlayerItem {
        PlayerItem(episode: episode, showTitle: show?.title ?? "",
                   showArtworkURL: show?.artworkURL, resume: resume(for: episode))
    }

    // MARK: - Fortsetzungsstelle

    /// Wo die Folge zuletzt gehört wurde, über alle Geräte. Gilt die Stelle
    /// des Geräts, das die ganze Folge zuletzt gehört hat
    /// (`MediaListeningState.merged(with:)`).
    public func resume(for episode: Episode) -> MediaTime? {
        guard let media = episode.streamMediaVersionID?.rawValue else { return nil }
        return mergedState(media: media)?.resumePosition
    }

    private func mergedState(media: String) -> MediaListeningState? {
        let rows = (try? context.fetch(FetchDescriptor<StoredListeningState>(
            predicate: #Predicate { $0.mediaVersionIdentifier.starts(with: media) }))) ?? []
        var result: MediaListeningState?
        for row in rows where row.mediaKey == media {
            let snapshot = row.snapshot
            result = result.map { $0.merged(with: snapshot) } ?? snapshot
        }
        return result
    }

    /// Schreibt, dass ein Bereich der Folge gehört wurde, und rückt die
    /// Fortsetzungsstelle an dessen Ende. Nur die Zeile dieses Geräts. Alle
    /// Felder der Zeile werden gesetzt, damit kein anderes Gerät eine Zeile
    /// mit fehlenden Feldern liest.
    public func recordPlayed(_ item: PlayerItem, range: MediaTimeRange, at date: Date = Date()) {
        guard !range.isEmpty, let media = item.episode.streamMediaVersionID else { return }
        let key = StoredListeningState.rowKey(media: media.rawValue, deviceID: deviceID)
        let existing = (try? context.fetch(FetchDescriptor<StoredListeningState>(
            predicate: #Predicate { $0.mediaVersionIdentifier == key })))?.first
        let row = existing ?? StoredListeningState(mediaVersionIdentifier: key)
        var state = row.snapshot
        state.apply(LedgerEvent(
            mediaVersionID: media, range: range, kind: .played, at: date,
            via: .originalEpisode, deviceID: deviceID))
        row.apply(state)
        if existing == nil { context.insert(row) }
        try? context.save()
    }

    // MARK: - Feeds

    /// Holt den Feed eines Podcasts und legt neue Folgen ab: im Speicher, mit
    /// Abgleich nie in der Datenbank. Gibt die Zahl der Folgen zurück, die
    /// vorher nicht bekannt waren.
    @discardableResult
    public func refresh(_ show: Source) async throws -> Int {
        guard let feedURL = show.feedURL else { return 0 }
        let parsed = try await FeedImport.fetch(feedURL, using: session)
        let fetched = FeedImport.episodes(from: parsed, sourceID: show.id)
        let known = Set(episodes(for: show, limit: .max).map(\.id))
        let removed = removedEpisodeIDs(sourceIdentifier: show.id.rawValue)
        let fresh = fetched.filter { !known.contains($0.id) && !removed.contains($0.id) }
        overlay[show.id] = fetched.filter { !removed.contains($0.id) }
        if storage != .synced, !fresh.isEmpty {
            persist(fresh, for: show)
        }
        reload()
        return fresh.count
    }

    /// Alle Abos nacheinander. Ein Fehler bei einem Feed hält die anderen
    /// nicht auf.
    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for show in shows {
            if Task.isCancelled { break }
            _ = try? await refresh(show)
        }
    }

    /// Nur ohne Abgleich: legt Folgen in der lokalen Datenbank ab.
    private func persist(_ episodes: [Episode], for show: Source) {
        let sid = show.id.rawValue
        guard let source = (try? context.fetch(FetchDescriptor<StoredSource>(
            predicate: #Predicate { $0.identifier == sid })))?.first else { return }
        for episode in episodes {
            let row = StoredEpisode(identifier: episode.id.rawValue, title: episode.title)
            row.summary = episode.summary
            row.publishedAt = episode.publishedAt
            row.declaredDurationMs = Int(episode.declaredDuration?.milliseconds ?? 0)
            row.webPageURLString = episode.webPageURL?.absoluteString
            row.audioURLString = episode.audioURL?.absoluteString
            row.artworkURLString = episode.artworkURL?.absoluteString
            row.chaptersData = episode.publisherChapters.isEmpty
                ? nil : try? JSONEncoder().encode(episode.publisherChapters)
            row.chaptersURLString = episode.chaptersURL?.absoluteString
            row.shownotesHTML = episode.shownotesHTML
            row.author = episode.author
            row.episodeNumber = episode.episodeNumber
            row.season = episode.season
            row.episodeType = episode.episodeType
            row.source = source
            context.insert(row)
        }
        try? context.save()
    }

    // MARK: - Nur für Tests

    func insertForTesting(source: Source) {
        let row = StoredSource(identifier: source.id.rawValue, kind: source.kind, title: source.title)
        row.feedURLString = source.feedURL?.absoluteString
        row.artworkURLString = source.artworkURL?.absoluteString
        row.isSubscribed = source.isSubscribed
        row.addedAt = source.addedAt
        context.insert(row)
        try? context.save()
    }

    func insertForTesting(episode: Episode, removedAt: Date? = nil) {
        let sid = episode.sourceID.rawValue
        let row = StoredEpisode(identifier: episode.id.rawValue, title: episode.title)
        row.publishedAt = episode.publishedAt
        row.audioURLString = episode.audioURL?.absoluteString
        row.declaredDurationMs = Int(episode.declaredDuration?.milliseconds ?? 0)
        row.removedAt = removedAt
        row.source = (try? context.fetch(FetchDescriptor<StoredSource>(
            predicate: #Predicate { $0.identifier == sid })))?.first
        context.insert(row)
        try? context.save()
    }

    func insertListeningRowForTesting(
        media: MediaVersionID, deviceID: String, state: MediaListeningState
    ) {
        let row = StoredListeningState(
            mediaVersionIdentifier: StoredListeningState.rowKey(media: media.rawValue, deviceID: deviceID))
        row.apply(state)
        context.insert(row)
        try? context.save()
    }

    func listeningRowKeysForTesting() -> [String] {
        ((try? context.fetch(FetchDescriptor<StoredListeningState>())) ?? []).map(\.mediaVersionIdentifier)
    }
}
#endif
