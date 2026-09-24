//
//  AppModel+Social.swift
//  PodcastAI
//
//  Was ein eigener Supadata-Schlüssel über YouTube-Untertitel hinaus öffnet:
//
//  * Einzelne Beiträge von TikTok, Instagram, X und Facebook als Folge,
//    abgelegt unter ihrem Urheber als Quelle, die nicht abonniert ist.
//    Metadaten über `/v1/metadata`, Transkript aus vorhandenen Untertiteln
//    (`mode=native`). Gibt es keine, bleibt es bei den Metadaten; eine
//    Transkription durch Supadata selbst fordert die App nie an.
//  * YouTube-Kanäle nach Namen suchen.
//  * Ältere Videos eines Kanals laden, über die 15 des Feeds hinaus.
//
//  Profile von TikTok oder Instagram lassen sich nicht abonnieren: Supadata
//  beschreibt keine Profile, und die App liest Profilseiten nicht selbst aus.
//  Ohne Schlüssel sagt die App das in einem Satz und ändert sonst nichts.
//

import Foundation
import PodcastAIKit

/// Warum ein Beitrag oder eine Suche nicht ging, in einem Satz.
enum SupadataFeatureError: Error, LocalizedError {
    /// Ohne eigenen Schlüssel gibt es Beiträge aus sozialen Netzen nicht.
    case needsKey(SocialPlatform)
    /// Profile lassen sich nicht abonnieren.
    case profileNotSupported
    /// Der Kanal nennt im Feed keine Kennung.
    case noChannelID
    case supadata(SupadataError)

    var errorDescription: String? {
        switch self {
        case .needsKey(let platform):
            String(localized: """
                Beiträge von \(platform.displayName) fügt die App mit einem eigenen Supadata-Schlüssel hinzu. \
                Du trägst ihn in den Einstellungen unter „YouTube-Transkripte (Supadata)“ ein.
                """)
        case .profileNotSupported:
            String(localized: """
                Ein Abo auf TikTok- oder Instagram-Profile ist nicht möglich. Teile einzelne Beiträge, \
                um sie hinzuzufügen.
                """)
        case .noChannelID:
            String(localized: "Zu diesem Kanal fehlt die Kennung, ältere Videos lassen sich nicht laden.")
        case .supadata(let error):
            error.errorDescription
        }
    }
}

extension AppModel {

    // MARK: - Beiträge aus sozialen Netzen

    /// Ist die Eingabe ein Beitrag oder Profil aus einem sozialen Netz?
    static func socialLink(in input: String) -> SocialLink? {
        URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(SocialLinks.classify)
    }

    /// Legt einen einzelnen Beitrag als Folge an und stößt sein Transkript an.
    func addSocialPost(_ link: SocialLink) async throws -> AddedSource {
        guard case .post(let platform, let url) = link else { throw SupadataFeatureError.profileNotSupported }
        guard allowsSupadataRequests, let apiKey = SupadataKeychain.read() else {
            throw SupadataFeatureError.needsKey(platform)
        }
        let metadata: SupadataMetadata
        do {
            metadata = try await supadata.metadata(for: url, apiKey: apiKey)
        } catch {
            if error == .unauthorized {
                supadataKeyRejected = true
                supadataKeyCheck = .rejected
            }
            throw SupadataFeatureError.supadata(error)
        }
        // Aus einem Kurzlink wird die volle Adresse, sofern sie ein Beitrag bleibt.
        let postURL: URL
        if let full = metadata.url, case .post(_, let canonical)? = SocialLinks.classify(full) {
            postURL = canonical
        } else {
            postURL = url
        }

        let creator = metadata.authorName ?? metadata.authorUsername ?? platform.displayName
        let creatorKey = metadata.authorUsername ?? metadata.authorName ?? "unbekannt"
        let sourceID = SourceID(stable: "supadata|\(platform.rawValue)|\(creatorKey.lowercased())")
        let existing = sources.first { $0.id == sourceID }
        let source = Source(
            id: sourceID, kind: .singleEpisodeLink, title: existing?.title ?? creator,
            author: platform.displayName,
            artworkURL: existing?.artworkURL ?? metadata.authorAvatarURL,
            capabilities: SourceCapabilities(metadata: true, audioDownload: false, embeddedPlayerOnly: true),
            isSubscribed: false,
            addedAt: existing?.addedAt ?? Date())
        let title = metadata.title
            ?? metadata.description.map { String($0.split(whereSeparator: \.isNewline).first ?? "").prefix(90) }
                .map(String.init)
            ?? String(localized: "Beitrag von \(creator)")
        let episode = Episode(
            id: EpisodeID(stable: "\(sourceID.rawValue)|\(postURL.absoluteString)"),
            sourceID: sourceID, title: title.isEmpty ? String(localized: "Beitrag von \(creator)") : title,
            summary: metadata.description, publishedAt: metadata.createdAt ?? Date(),
            declaredDuration: metadata.duration, artworkURL: metadata.thumbnailURL,
            webPageURL: postURL)

        try await store.upsert(source: source)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        supadataMetadata[postURL.absoluteString] = metadata
        Self.saveSupadataMetadata(supadataMetadata)
        sources = withSupadataMetadata(sources: try await store.sources())
        await loadEpisodes(for: sourceID)
        // Von Hand hinzugefügt heißt: Transkript gleich anfordern. Die Regeln
        // fürs Netz gelten wie bei jeder Folge.
        if let stored = episodes[sourceID]?.first(where: { $0.id == episode.id }) {
            enqueueAnalysis(stored)
        }
        return AddedSource(title: source.title, episodeCount: 1)
    }

    // MARK: - YouTube-Kanäle suchen

    /// Sucht YouTube-Kanäle über Supadata. Nur auf ausdrücklichen Wunsch,
    /// denn jede Suche kostet bei Supadata.
    func searchYouTubeChannels(_ term: String) async throws -> [SupadataChannel] {
        guard allowsSupadataRequests, let apiKey = SupadataKeychain.read() else {
            throw SupadataFeatureError.supadata(.missingKey)
        }
        do {
            return try await supadata.searchChannels(term, apiKey: apiKey)
        } catch {
            if error == .unauthorized {
                supadataKeyRejected = true
                supadataKeyCheck = .rejected
            }
            throw SupadataFeatureError.supadata(error)
        }
    }

    // MARK: - Ältere Videos eines Kanals

    /// Die Kanalkennung aus dem Feed eines YouTube-Kanals.
    static func youTubeChannelID(of source: Source) -> String? {
        guard source.kind == .youTubeChannel, let feed = source.feedURL,
              let id = URLComponents(url: feed, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "channel_id" })?.value,
              SourceResolver.isValidChannelID(id) else { return nil }
        return id
    }

    /// Lädt bis zu `count` Videos des Kanals, die noch nicht in der Liste
    /// stehen, neueste zuerst. Je Video eine Anfrage für die Metadaten; bei
    /// einem Fehler endet der Lauf mit dem, was schon da ist.
    /// Gibt die Zahl neuer Folgen zurück.
    func loadOlderYouTubeVideos(of sourceID: SourceID, count: Int = 20) async throws -> Int {
        guard let source = sources.first(where: { $0.id == sourceID }),
              let channelID = Self.youTubeChannelID(of: source) else { throw SupadataFeatureError.noChannelID }
        guard allowsSupadataRequests, let apiKey = SupadataKeychain.read() else {
            throw SupadataFeatureError.supadata(.missingKey)
        }
        let known = Set((episodes[sourceID] ?? []).compactMap { YouTubeLinks.videoID(in: $0.webPageURL) })
        let list: SupadataVideoList
        do {
            list = try await supadata.channelVideos(channelID: channelID, apiKey: apiKey,
                                                     limit: known.count + count + 15)
        } catch {
            throw SupadataFeatureError.supadata(error)
        }
        let missing = list.all.filter { !known.contains($0) }.prefix(count)
        var added: [Episode] = []
        for videoID in missing {
            guard let watch = SourceResolver.watchURL(videoID: videoID) else { continue }
            guard let metadata = try? await supadata.metadata(for: watch, apiKey: apiKey) else { break }
            supadataMetadata[watch.absoluteString] = metadata
            // Dieselbe Kennung wie aus dem Feed, damit ein späteres Einlesen
            // die Folge nicht verdoppelt.
            added.append(Episode(
                id: EpisodeID(stable: "\(sourceID.rawValue)|yt:video:\(videoID)"),
                sourceID: sourceID, title: metadata.title ?? videoID, summary: metadata.description,
                publishedAt: metadata.createdAt, declaredDuration: metadata.duration,
                artworkURL: metadata.thumbnailURL, webPageURL: watch))
        }
        Self.saveSupadataMetadata(supadataMetadata)
        guard !added.isEmpty else { return 0 }
        let inserted = try await store.upsert(episodes: added, forSource: sourceID)
        episodes[sourceID] = withSupadataMetadata(try await store.episodes(forSource: sourceID))
        RemoteMediaRegistry.shared.register(episodes[sourceID] ?? [])
        return inserted
    }
}
