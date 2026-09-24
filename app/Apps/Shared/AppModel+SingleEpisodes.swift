//
//  AppModel+SingleEpisodes.swift
//  PodcastAI
//
//  „Nur diese Folge“ und „Nur dieses Video“: eine Folge in die Bibliothek
//  holen, ohne den Podcast oder Kanal zu abonnieren. Die Folge läuft durch
//  dieselbe Erschließung wie alle anderen und steht in der Warteschlange
//  vor dem Archiv. Abgespielt wird dabei nichts.
//

import Foundation
import SwiftUI
import PodcastAIKit

extension AppModel {

    /// Sieht nach, was ein eingefügter Link anbietet. Legt nichts an.
    public func inspectLink(_ input: String) async throws -> LinkTarget {
        activity = String(localized: "Link wird geprüft …")
        defer { activity = nil }
        var target = try await refresher.inspect(input)
        if case .youTube(var preview) = target {
            preview.counterparts = await counterparts(forChannel: preview.channelName)
            target = .youTube(preview)
        }
        return target
    }

    /// Audio-Podcasts zu einem Kanalnamen, ohne die schon abonnierten.
    func counterparts(forChannel name: String) async -> [PodcastCounterpart] {
        let found = await PodcastDirectory.counterparts(forChannel: name)
        let subscribed = Set(sources.filter(\.isSubscribed).compactMap(\.feedURL))
        return found.filter { !subscribed.contains($0.feedURL) }
    }

    /// Holt eine Folge aus der Vorschau eines Podcasts.
    @discardableResult
    public func addSingleEpisode(key: String, from preview: PodcastPreview) async throws -> AddedSource {
        let added = try await refresher.addSingleEpisode(key: key, from: preview)
        await singleEpisodeAdded(feedURL: preview.feedURL, title: added.title)
        return added
    }

    /// Holt das Video aus einem YouTube-Link unter seinen Kanal.
    @discardableResult
    public func addSingleVideo(from preview: YouTubeLinkPreview) async throws -> AddedSource {
        let added = try await refresher.addSingleVideo(from: preview)
        await singleEpisodeAdded(feedURL: preview.channelFeedURL, title: added.title)
        return added
    }

    /// Eine Folgenseite ohne Feed: die Datei landet wie ein Audiolink in
    /// „Einzelne Folgen“, mit dem Titel der Seite.
    @discardableResult
    public func addAudioEpisode(_ url: URL, title: String?) async throws -> AddedSource {
        let added = try await refresher.addSingleEpisode(url, title: title)
        sources = try await store.sources()
        for source in sources where source.kind == .singleEpisodeLink {
            await loadEpisodes(for: source.id)
        }
        return added
    }

    /// Abonniert einen Podcast oder Kanal, aus dem bisher nur einzelne
    /// Folgen in der Bibliothek liegen. Die Folgen bleiben, wie sie sind.
    public func subscribeToSource(_ source: Source) async {
        guard let feed = source.feedURL else { return }
        await addSource(from: feed.absoluteString)
    }

    /// Liest die Quellen neu und reiht die neue Folge ein. `loadEpisodes`
    /// bereitet sie vor wie jede neue Folge, sofern das eingeschaltet ist.
    private func singleEpisodeAdded(feedURL: URL?, title: String) async {
        do {
            sources = try await store.sources()
        } catch {
            lastError = UserFacingError.describe(error)
            return
        }
        if let feedURL, let source = sources.first(where: { $0.feedURL == feedURL }) {
            await loadEpisodes(for: source.id)
        }
        AccessibilityNotification.Announcement(String(localized: "Folge hinzugefügt: \(title)")).post()
    }
}
