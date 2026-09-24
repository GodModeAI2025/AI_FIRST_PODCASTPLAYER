//
//  AppModel+SourceReload.swift
//  PodcastAI
//
//  „Neu laden“ für eine einzelne Quelle: Feed, Kanal oder Playlist noch
//  einmal lesen, samt Metadaten, Bild, Folgen und Kapiteln. Derselbe Weg
//  wie das Aktualisieren aller Abos, nur für eine Quelle. Abgespielt wird
//  dabei nichts, und das Abo bleibt, wie es ist.
//

import Foundation
import SwiftUI
import PodcastAIKit

/// Was das letzte „Neu laden“ einer Quelle ergeben hat.
public enum SourceReloadResult: Equatable, Sendable {
    case done(newEpisodes: Int)
    /// Kein Abo: neue Folgen kommen nicht dazu, die geholten sind frisch.
    case doneWithoutSubscription
    case failed(String)

    var text: String {
        switch self {
        case .done(let count) where count > 0:
            String(AttributedString(localized: "Neu geladen, ^[\(count) neue Folge](inflect: true).").characters)
        case .done:
            String(localized: "Neu geladen, keine neuen Folgen.")
        case .doneWithoutSubscription:
            String(localized: "Neu geladen. Neue Folgen kommen erst nach dem Abonnieren.")
        case .failed(let reason):
            reason
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension AppModel {

    /// Lässt sich die Quelle neu laden? Nur mit einem Feed im Netz.
    func canReload(_ source: Source) -> Bool {
        guard let scheme = source.feedURL?.scheme?.lowercased() else { return false }
        return source.kind != .localFile && (scheme == "https" || scheme == "http")
    }

    /// Liest den Feed einer Quelle neu und zeigt danach Titel, Beschreibung,
    /// Bild und Folgen frisch an. Fehlt dem Feed ein Bild, sucht die App es
    /// im Podcast-Verzeichnis. Für YouTube holt sie mit aktivem
    /// Supadata-Schlüssel die Metadaten der neuesten Videos neu.
    ///
    /// Den Feed holt die App wie beim Aktualisieren aller Abos auch über
    /// Mobilfunk, er ist klein. Supadata fragt sie dort nur mit Zustimmung.
    public func reloadSource(_ sourceID: SourceID) async {
        wakeRestingPreparation(in: sourceID)
        let newEpisodes = await runReload(sourceID)
        // Neue Folgen bereitet die App vor wie nach dem Aktualisieren aller
        // Abos, nach denselben Regeln fürs Netz. Abgespielt wird nichts. Erst
        // nach dem Ergebnis, damit die Seite nicht so lange „Wird neu
        // geladen …“ zeigt.
        if newEpisodes > 0 { await prepareNewEpisodes(in: sourceID) }
    }

    /// Das eigentliche Neuladen. Gibt die Zahl neuer Folgen zurück.
    private func runReload(_ sourceID: SourceID) async -> Int {
        guard !reloadingSources.contains(sourceID),
              let shown = sources.first(where: { $0.id == sourceID }), canReload(shown) else { return 0 }
        guard !isOffline else {
            sourceReloadResults[sourceID] = .failed(String(localized: "Keine Verbindung. Neu laden geht, sobald das Gerät online ist."))
            return 0
        }
        reloadingSources.insert(sourceID)
        sourceReloadResults[sourceID] = nil
        // Auch unter „Meine Podcasts“ sichtbar, wo es keine Zeile dafür gibt.
        activity = String(localized: "„\(shown.title)“ wird neu geladen …")
        var newEpisodes = 0
        defer {
            reloadingSources.remove(sourceID)
            activity = nil
            AccessibilityNotification.Announcement(sourceReloadResults[sourceID]?.text ?? "").post()
        }

        do {
            // Aus der Datenbank, nicht aus `sources`: dort stehen auch Lücken,
            // die Supadata gefüllt hat, und die gehören nicht in den Feed.
            guard let stored = try await store.sources().first(where: { $0.id == sourceID }) else { return 0 }
            var result = try await refresher.reload(stored, feedData: Self.fixtureFeed(for: stored))
            if !result.feedHasArtwork, stored.kind == .podcastRSS, let feedURL = stored.feedURL,
               let found = await directoryArtwork(forFeed: feedURL, title: result.source.title),
               found != result.source.artworkURL {
                var updated = result.source
                updated.artworkURL = found
                try await store.updateFeedMetadata(of: updated)
                result = FeedRefresher.SourceReload(source: updated, newEpisodes: result.newEpisodes,
                                                    feedHasArtwork: false)
            }

            sources = withSupadataMetadata(sources: try await store.sources())
            let list = try await store.episodes(forSource: sourceID)
            // Während des Ladens entfernt: nicht wieder eintragen.
            if sources.contains(where: { $0.id == sourceID }) {
                episodes[sourceID] = withSupadataMetadata(list)
                RemoteMediaRegistry.shared.register(list)
            }
            // Kapiteldateien beim nächsten Öffnen einer Folge neu lesen.
            for episode in list { chapterCache[episode.id] = nil }
            // Bilder unter derselben Adresse können sich geändert haben.
            let artwork = [shown.artworkURL, stored.artworkURL, result.source.artworkURL]
                + list.prefix(20).map(\.artworkURL)
            ArtworkRefresh.shared.reload(artwork.compactMap { $0 })

            if stored.kind == .youTubeChannel {
                await refreshSupadataMetadata(in: sourceID)
            }
            sourceReloadResults[sourceID] = stored.refreshesAutomatically
                ? .done(newEpisodes: result.newEpisodes) : .doneWithoutSubscription
            newEpisodes = result.newEpisodes
        } catch is CancellationError {
            return 0
        } catch {
            sourceReloadResults[sourceID] = .failed(
                String(localized: "Neu laden hat nicht geklappt. \(UserFacingError.describe(error))"))
        }
        return newEpisodes
    }

    /// Das Bild aus dem Apple-Podcast-Verzeichnis, wenn der Feed keins
    /// nennt. Gesucht wird nach dem Titel; zählt nur ein Treffer mit genau
    /// diesem Feed.
    private func directoryArtwork(forFeed feedURL: URL, title: String) async -> URL? {
        guard title.count >= 2,
              let results = try? await PodcastCatalog.shared.searchApple(title) else { return nil }
        let key = CatalogMerge.feedKey(feedURL)
        return results.first { podcast in
            ([podcast.feedURL] + podcast.alternateFeedURLs).contains { CatalogMerge.feedKey($0) == key }
        }?.artworkURL
    }

    /// In UI-Tests mit `-catalog-fixtures` kommt der Feed aus den festen
    /// Beispielen, ohne Netz. Sonst `nil`.
    private static func fixtureFeed(for source: Source) -> Data? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-catalog-fixtures"),
              let feedURL = source.feedURL else { return nil }
        return CatalogFixtures.feed(for: feedURL)
        #else
        return nil
        #endif
    }
}

/// Lässt Bilder neu laden, deren Inhalt sich unter derselben Adresse
/// geändert haben kann. `AsyncImage` lädt über `URLCache.shared` und lädt
/// ein schon gezeigtes Bild nicht von selbst neu. Nach „Neu laden“ fliegt
/// der Eintrag aus dem Cache, und die Ansicht bekommt eine neue Identität.
@MainActor @Observable
final class ArtworkRefresh {

    static let shared = ArtworkRefresh()

    private var revisions: [URL: Int] = [:]

    func revision(for url: URL?) -> Int {
        url.flatMap { revisions[$0] } ?? 0
    }

    func reload(_ urls: [URL]) {
        for url in Set(urls) {
            URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
            revisions[url, default: 0] += 1
        }
    }
}

// MARK: - Oberfläche

/// Der Knopf „Neu laden“ für eine Quelle. Während des Ladens ist er
/// gesperrt; den Fortschritt zeigt `SourceReloadStatus`.
struct SourceReloadButton: View {
    let source: Source
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.canReload(source) {
            Button {
                Task { await model.reloadSource(source.id) }
            } label: {
                Label("Neu laden", systemImage: "arrow.clockwise")
            }
            .disabled(model.reloadingSources.contains(source.id))
            .accessibilityHint("Liest Feed, Beschreibung, Bild und Folgen dieser Quelle neu")
            .accessibilityIdentifier("source.reload")
        }
    }
}

/// Eine ruhige Zeile oben auf der Seite einer Quelle: „Wird neu geladen …“,
/// danach das Ergebnis oder der Fehler.
struct SourceReloadStatus: View {
    let sourceID: SourceID
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.reloadingSources.contains(sourceID) {
            Section {
                Label {
                    Text("Wird neu geladen …")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("source.reloading")
            }
        } else if let result = model.sourceReloadResults[sourceID] {
            Section {
                NoticeLabel(result.text, kind: result.isFailure ? .failure : .info)
                    .accessibilityIdentifier("source.reloadStatus")
            }
        }
    }
}
