//
//  SupadataViews.swift
//  PodcastAI
//
//  Was nur mit eigenem Supadata-Schlüssel erscheint: YouTube-Kanäle suchen
//  und ältere Videos eines Kanals laden. Beides kostet bei Supadata und
//  passiert deshalb nur auf Tippen, nie beim Tippen ins Suchfeld.
//

import SwiftUI
import PodcastAIKit

/// Unter den Treffern im Blatt „Podcast hinzufügen“: dieselbe Eingabe als
/// Suche nach YouTube-Kanälen.
struct YouTubeChannelSearchSection: View {

    let term: String
    @Environment(AppModel.self) private var model
    @State private var channels: [SupadataChannel] = []
    @State private var searchedTerm: String?
    @State private var searching = false
    @State private var failure: String?
    @State private var subscribing: Set<String> = []
    @State private var subscribed: Set<String> = []

    var body: some View {
        Section {
            if searchedTerm != term {
                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Label("„\(term)“ bei YouTube suchen", systemImage: "play.rectangle")
                        Spacer()
                        if searching { ProgressView() }
                    }
                }
                .disabled(searching)
                .accessibilityIdentifier("source.searchYouTube")
            } else if channels.isEmpty, failure == nil {
                Text("Keine YouTube-Kanäle gefunden.").foregroundStyle(.secondary)
            }
            if let failure {
                NoticeLabel(failure, kind: .info)
            }
            ForEach(channels) { channel in
                HStack(spacing: Design.Spacing.control) {
                    EpisodeArtwork(url: channel.thumbnailURL, size: 44)
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                        Text(channel.title).font(.headline).lineLimit(2)
                        if let handle = channel.handle {
                            Text(handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if subscribed.contains(channel.id) || channel.feedURL.map(model.isSubscribed) == true {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Abonniert")
                    } else if subscribing.contains(channel.id) {
                        ProgressView()
                    } else if let feed = channel.feedURL {
                        Button("Abonnieren") { Task { await subscribe(channel.id, feed: feed) } }
                            .buttonStyle(.bordered)
                    }
                }
            }
        } header: {
            Text("YouTube-Kanäle (Supadata)")
        } footer: {
            Text("Die Suche geht mit deinem Schlüssel an Supadata und kostet dort wie ein Abruf.")
        }
    }

    private func search() async {
        searching = true
        failure = nil
        defer { searching = false }
        do {
            channels = try await model.searchYouTubeChannels(term)
        } catch {
            channels = []
            failure = UserFacingError.describe(error)
        }
        searchedTerm = term
    }

    private func subscribe(_ id: String, feed: URL) async {
        subscribing.insert(id)
        defer { subscribing.remove(id) }
        do {
            try await model.subscribe(to: feed.absoluteString)
            subscribed.insert(id)
        } catch {
            failure = UserFacingError.describe(error)
        }
    }
}

/// In der Folgenliste eines YouTube-Kanals: ältere Videos über Supadata.
struct OlderYouTubeVideosSection: View {

    let sourceID: SourceID
    @Environment(AppModel.self) private var model
    @State private var loading = false
    @State private var result: String?

    var body: some View {
        Section {
            Button {
                Task { await load() }
            } label: {
                HStack {
                    Label("20 ältere Videos über Supadata laden", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    if loading { ProgressView() }
                }
            }
            .disabled(loading)
            .accessibilityIdentifier("episodes.olderYouTube")
            if let result {
                Text(result).font(.callout).foregroundStyle(.secondary)
            }
        } footer: {
            Text("""
                Der Feed von YouTube nennt nur die 15 neuesten Videos. Mit deinem Schlüssel holt die App \
                weitere über Supadata, je Video ein Abruf.
                """)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let added = try await model.loadOlderYouTubeVideos(of: sourceID)
            result = added == 0
                ? String(localized: "Keine weiteren Videos gefunden.")
                : String(AttributedString(localized: "^[\(added) Video](inflect: true) dazugekommen.").characters)
        } catch {
            result = UserFacingError.describe(error)
        }
    }
}
