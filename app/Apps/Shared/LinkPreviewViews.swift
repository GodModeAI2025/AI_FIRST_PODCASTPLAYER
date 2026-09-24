//
//  LinkPreviewViews.swift
//  PodcastAI
//
//  Vorschau zu einem eingefügten Link: ein Podcast mit der Folge aus dem
//  Link oder ein YouTube-Kanal mit seinen Möglichkeiten. Dazu „Nur diese
//  Folge“ in der Seite eines Podcasts aus dem Katalog.
//
//  Abgespielt wird hier nichts. Titel, Beschreibungen und Bilder kommen von
//  fremden Seiten und stehen nur da.
//

import SwiftUI
import PodcastAIKit

// MARK: - Routen

extension PodcastLinkPreview: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension YouTubeLinkPreview: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension CatalogFormat {
    /// „12. Sept. 2026 · 45 Min.“
    static func episodeLine(_ episode: PodcastPreview.Item) -> String {
        [episode.publishedAt.map { $0.formatted(date: .abbreviated, time: .omitted) },
         duration(episode.duration)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: - Einzeln holen und abonnieren

extension CatalogSubscriptions {

    static func singleKey(feed: URL?, key: String) -> String {
        "\(feed?.absoluteString ?? "")|\(key)"
    }

    func singleState(_ episode: PodcastPreview.Item, in preview: PodcastPreview) -> CatalogPodcastRow.State {
        let key = Self.singleKey(feed: preview.feedURL, key: episode.key)
        if singles.contains(key) { return .added(1) }
        return workingSingles.contains(key) ? .working : .open
    }

    func addSingle(_ episode: PodcastPreview.Item, from preview: PodcastPreview, model: AppModel) async {
        let key = Self.singleKey(feed: preview.feedURL, key: episode.key)
        guard !workingSingles.contains(key), !singles.contains(key) else { return }
        workingSingles.insert(key)
        linkFailure = nil
        defer { workingSingles.remove(key) }
        do {
            try await model.addSingleEpisode(key: episode.key, from: preview)
            singles.insert(key)
        } catch is CancellationError {
            return
        } catch {
            linkFailure = UserFacingError.describe(error)
        }
    }

    func videoState(_ preview: YouTubeLinkPreview) -> CatalogPodcastRow.State {
        guard let video = preview.video else { return .open }
        let key = Self.singleKey(feed: preview.channelFeedURL, key: video.id)
        if singles.contains(key) { return .added(1) }
        return workingSingles.contains(key) ? .working : .open
    }

    func addVideo(from preview: YouTubeLinkPreview, model: AppModel) async {
        guard let video = preview.video else { return }
        let key = Self.singleKey(feed: preview.channelFeedURL, key: video.id)
        guard !workingSingles.contains(key), !singles.contains(key) else { return }
        workingSingles.insert(key)
        linkFailure = nil
        defer { workingSingles.remove(key) }
        do {
            try await model.addSingleVideo(from: preview)
            singles.insert(key)
        } catch is CancellationError {
            return
        } catch {
            linkFailure = UserFacingError.describe(error)
        }
    }

    /// Abo-Zustand eines Feeds aus einer Link-Vorschau.
    func state(ofFeed url: URL, in model: AppModel) -> CatalogPodcastRow.State {
        if let count = added[url] { return .added(count) }
        let key = CatalogMerge.feedKey(url)
        if model.sources.contains(where: { $0.isSubscribed && $0.feedURL.map(CatalogMerge.feedKey) == key }) {
            return .subscribed
        }
        return working.contains(url) ? .working : .open
    }

    func subscribe(feed url: URL, model: AppModel) async {
        guard !working.contains(url) else { return }
        working.insert(url)
        linkFailure = nil
        defer { working.remove(url) }
        do {
            let result = try await model.subscribe(to: url.absoluteString)
            added[url] = result.episodeCount
        } catch is CancellationError {
            return
        } catch {
            linkFailure = UserFacingError.describe(error)
        }
    }
}

// MARK: - Bausteine

/// Eine Folge aus der Vorschau eines Podcasts, auf Wunsch mit „Nur diese
/// Folge“ daneben.
struct PreviewEpisodeRow: View {
    let episode: PodcastPreview.Item
    let preview: PodcastPreview
    let offersSingle: Bool

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).lineLimit(3)
                let line = CatalogFormat.episodeLine(episode)
                if !line.isEmpty {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if offersSingle, episode.canBeAdded {
                switch subscriptions.singleState(episode, in: preview) {
                case .open:
                    Button("Nur diese Folge") {
                        Task { await subscriptions.addSingle(episode, from: preview, model: model) }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Nur diese Folge: \(episode.title)")
                    .accessibilityIdentifier("episode.single")
                case .working:
                    ProgressView()
                case .subscribed, .added:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("In deiner Bibliothek")
                        .accessibilityIdentifier("episode.single.done")
                }
            }
        }
    }
}

/// Ein Knopf mit Zustand: offen, in Arbeit, erledigt.
private struct OptionButton: View {
    let title: LocalizedStringKey
    var detail: String?
    let systemImage: String
    let state: CatalogPodcastRow.State
    let done: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        switch state {
        case .open, .working:
            Button(action: action) {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                            if let detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    Spacer()
                    if state == .working { ProgressView() }
                }
            }
            .disabled(state == .working)
            .accessibilityIdentifier(identifier)
        case .subscribed, .added:
            Label(done, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier(identifier + ".done")
        }
    }
}

/// Bild, Name und Anbieter oben auf einer Vorschau.
private struct PreviewHeader: View {
    let artworkURL: URL?
    let title: String
    let subtitle: String?
    @ScaledMetric(relativeTo: .title) private var artworkSize: CGFloat = 140

    var body: some View {
        VStack(spacing: Design.Spacing.small) {
            PodcastArtwork(url: artworkURL, size: min(artworkSize, 240))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Design.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Podcast aus einem Folgenlink

/// Der Podcast hinter einem Folgenlink, mit „Nur diese Folge“ und
/// „Abonnieren“.
struct LinkPodcastView: View {
    let link: PodcastLinkPreview

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions

    private var subscribeState: CatalogPodcastRow.State {
        link.feedURL.map { subscriptions.state(ofFeed: $0, in: model) } ?? .open
    }

    var body: some View {
        List {
            Section {
                PreviewHeader(artworkURL: link.artworkURL, title: link.title, subtitle: link.author)
            }

            if let episode = link.episode {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title).font(.headline).lineLimit(4)
                        let line = CatalogFormat.episodeLine(episode)
                        if !line.isEmpty {
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if subscribeState == .open || subscribeState == .working {
                        OptionButton(title: "Nur diese Folge", systemImage: "plus.circle",
                                     state: subscriptions.singleState(episode, in: link.preview),
                                     done: "In deiner Bibliothek, nicht abonniert",
                                     identifier: "link.single") {
                            Task { await subscriptions.addSingle(episode, from: link.preview, model: model) }
                        }
                    }
                    subscribeButton
                } header: {
                    Text("Folge aus dem Link")
                } footer: {
                    Text("„Nur diese Folge“ holt die Folge in deine Bibliothek, ohne den Podcast zu abonnieren. Sie steht dann unter dem Podcast, gekennzeichnet als nicht abonniert.")
                }
            } else {
                Section {
                    if link.episodeMissing {
                        NoticeLabel(String(localized: "Die Folge aus dem Link steht nicht mehr im Feed. Abonnieren bringt die Folgen, die der Feed führt."),
                                    kind: .info)
                    }
                    subscribeButton
                }
            }

            if let failure = subscriptions.linkFailure {
                Section { NoticeLabel(failure, kind: .failure) }
            }

            if let summary = ShownotesText.plain(link.preview.summary) {
                Section("Beschreibung") { Text(summary).textSelection(.enabled) }
            }

            if !link.preview.latest.isEmpty {
                Section("Neueste Folgen") {
                    ForEach(link.preview.latest) { episode in
                        PreviewEpisodeRow(episode: episode, preview: link.preview,
                                          offersSingle: subscribeState == .open)
                    }
                }
            }
        }
        .navigationTitle(link.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Ein Fehler gehört zu dieser Seite, nicht zur nächsten im Blatt.
        .onDisappear { subscriptions.linkFailure = nil }
    }

    @ViewBuilder private var subscribeButton: some View {
        if let feed = link.feedURL {
            OptionButton(title: "Abonnieren", systemImage: "plus.circle.fill",
                         state: subscribeState, done: "Abonniert",
                         identifier: "link.subscribe") {
                Task { await subscriptions.subscribe(feed: feed, model: model) }
            }
        }
    }
}

// MARK: - YouTube

/// Ein YouTube-Link vor dem Abonnieren: Kanal, neueste Videos und die
/// Möglichkeiten. Den passenden Audio-Podcast empfiehlt die App zuerst,
/// denn nur mit Ton gibt es Transkript, Fakten und Tags.
struct YouTubeLinkView: View {
    let link: YouTubeLinkPreview

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions

    var body: some View {
        List {
            Section {
                PreviewHeader(artworkURL: link.artworkURL, title: link.playlist?.title ?? link.channelName,
                              subtitle: link.playlist == nil ? String(localized: "YouTube-Kanal")
                                  : String(localized: "Playlist von \(link.channelName)"))
            }

            if !link.counterparts.isEmpty {
                Section {
                    ForEach(link.counterparts) { podcast in
                        OptionButton(title: "Passenden Audio-Podcast abonnieren",
                                     detail: [podcast.title, podcast.author].filter { !$0.isEmpty }.joined(separator: " · "),
                                     systemImage: "waveform.circle.fill",
                                     state: subscriptions.state(ofFeed: podcast.feedURL, in: model),
                                     done: "Audio-Podcast abonniert",
                                     identifier: "youtube.subscribeCounterpart") {
                            Task { await subscriptions.subscribe(feed: podcast.feedURL, model: model) }
                        }
                    }
                } header: {
                    Text("Empfohlen")
                } footer: {
                    Text("Nur mit Ton gibt es Transkript, Fakten und Tags. Den liefert der Audio-Podcast, YouTube nicht.")
                }
            }

            Section {
                if let playlist = link.playlist {
                    OptionButton(title: "Playlist abonnieren", systemImage: "music.note.list",
                                 state: subscriptions.state(ofFeed: playlist.feedURL, in: model),
                                 done: "Playlist abonniert", identifier: "youtube.subscribePlaylist") {
                        Task { await subscriptions.subscribe(feed: playlist.feedURL, model: model) }
                    }
                }
                if let feed = link.channelFeedURL {
                    OptionButton(title: "Kanal abonnieren", systemImage: "plus.circle.fill",
                                 state: subscriptions.state(ofFeed: feed, in: model),
                                 done: "Kanal abonniert", identifier: "youtube.subscribeChannel") {
                        Task { await subscriptions.subscribe(feed: feed, model: model) }
                    }
                }
                if link.video != nil, link.channelFeedURL != nil {
                    OptionButton(title: "Nur dieses Video", systemImage: "play.rectangle",
                                 state: subscriptions.videoState(link),
                                 done: "In deiner Bibliothek, nicht abonniert",
                                 identifier: "youtube.singleVideo") {
                        Task { await subscriptions.addVideo(from: link, model: model) }
                    }
                }
                if let failure = subscriptions.linkFailure {
                    NoticeLabel(failure, kind: .failure)
                }
            } footer: {
                Text("Von YouTube bekommt die App keinen Ton. Sie zeigt Titel, Beschreibung und Kapitel aus der Beschreibung und spielt Videos in der YouTube-App ab.")
            }

            if let video = link.video {
                Section("Video aus dem Link") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title).font(.headline).lineLimit(4)
                        if let date = video.publishedAt {
                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let summary = link.summary, !summary.isEmpty {
                Section("Beschreibung") { Text(summary).textSelection(.enabled) }
            }

            Section {
                if link.latest.isEmpty {
                    Text("YouTube liefert die Videoliste gerade nicht.").foregroundStyle(.secondary)
                }
                ForEach(link.latest) { video in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title).lineLimit(3)
                        let line = CatalogFormat.episodeLine(video)
                        if !line.isEmpty {
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Neueste Videos")
            } footer: {
                Text("YouTube nennt nur die 15 neuesten Videos. Ältere lassen sich nicht nachladen. Nach dem Abonnieren behält die App jedes Video, das sie einmal gesehen hat.")
            }
        }
        .navigationTitle(link.playlist?.title ?? link.channelName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear { subscriptions.linkFailure = nil }
    }
}
