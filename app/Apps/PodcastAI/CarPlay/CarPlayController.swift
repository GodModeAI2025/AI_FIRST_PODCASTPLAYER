//
//  CarPlayController.swift
//  PodcastAI (iOS)
//
//  Baut die Vorlagen für CarPlay: Tab-Leiste mit Abos, Neu und Warteschlange,
//  Folgenlisten und die Vorlage „Wiedergabe“ mit Tempo und „Als Nächstes“.
//
//  Gespielt wird über das vorhandene `AppModel` (`playEpisode`), also mit
//  demselben Player, derselben Fortsetzungsstelle und demselben Hörzustand
//  wie auf dem iPhone. Sprünge und Pause bedient das System über
//  `MPRemoteCommandCenter`, das `EpisodePlayer` schon füllt.
//
//  Nur Player: nichts davon berührt die KI-Funktionen der App.
//

import UIKit
import CarPlay
import Observation
import PodcastAIKit

@MainActor
final class CarPlayController: NSObject, CPNowPlayingTemplateObserver {

    private let model: AppModel
    private let interface: CPInterfaceController

    private let showsTemplate: CPListTemplate
    private let latestTemplate: CPListTemplate
    private let queueTemplate: CPListTemplate
    private var observing = true

    /// CarPlay zeigt höchstens so viele Zeilen; mehr würde es ohnehin kappen.
    private var rowLimit: Int { min(CPListTemplate.maximumItemCount, 50) }

    init(model: AppModel, interfaceController: CPInterfaceController) {
        self.model = model
        self.interface = interfaceController
        showsTemplate = Self.listTemplate(
            title: String(localized: "Abos", table: "CarPlay"), symbol: "square.stack",
            empty: String(localized: "Keine Abos", table: "CarPlay"),
            detail: String(localized: "Abonniere Podcasts auf dem iPhone.", table: "CarPlay"))
        latestTemplate = Self.listTemplate(
            title: String(localized: "Neu", table: "CarPlay"), symbol: "sparkles",
            empty: String(localized: "Keine neuen Folgen", table: "CarPlay"), detail: nil)
        queueTemplate = Self.listTemplate(
            title: String(localized: "Warteschlange", table: "CarPlay"), symbol: "list.bullet",
            empty: String(localized: "Nichts in der Warteschlange", table: "CarPlay"),
            detail: String(localized: "Reihe Folgen auf dem iPhone ein.", table: "CarPlay"))
        super.init()
    }

    private static func listTemplate(title: String, symbol: String, empty: String, detail: String?) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol) ?? UIImage()
        template.emptyViewTitleVariants = [empty]
        if let detail { template.emptyViewSubtitleVariants = [detail] }
        return template
    }

    // MARK: - Start

    func start() async {
        await model.ensureLoaded()
        refresh()
        let tabs = CPTabBarTemplate(templates: [showsTemplate, latestTemplate, queueTemplate])
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = String(localized: "Als Nächstes", table: "CarPlay")
        nowPlaying.add(self)
        nowPlaying.updateNowPlayingButtons([
            CPNowPlayingPlaybackRateButton { [weak self] _ in self?.cycleRate() },
        ])
        _ = try? await interface.setRootTemplate(tabs, animated: false)
        observeModel()
    }

    func stop() {
        observing = false
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: - Listen

    private func refresh() {
        showsTemplate.updateSections([CPListSection(items: showItems())])
        latestTemplate.updateSections([CPListSection(items: latestItems())])
        queueTemplate.updateSections([CPListSection(items: queueItems())])
    }

    /// Hängt sich an das Modell: ändern sich Abos, Folgen oder
    /// Warteschlange, baut sie die Listen neu. Erst nach einer kurzen Pause,
    /// weil das Laden viele Änderungen hintereinander meldet.
    private func observeModel() {
        guard observing else { return }
        withObservationTracking {
            _ = model.sources.count
            _ = model.episodes.values.reduce(0) { $0 + $1.count }
            _ = model.upNext.map(\.id)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.observing else { return }
                self.refresh()
                self.observeModel()
            }
        }
    }

    private func showItems() -> [CPListItem] {
        let shows = model.sources.filter(\.isSubscribed)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return shows.prefix(rowLimit).map { show in
            let count = (model.episodes[show.id] ?? []).filter(model.canPlay).count
            let item = CPListItem(
                text: show.title,
                detailText: count > 0 ? String(localized: "\(count) Folgen", table: "CarPlay") : nil,
                image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.openShow(show)
                    completion()
                }
            }
            loadArtwork(for: item, url: show.artworkURL)
            return item
        }
    }

    private func latestItems() -> [CPListItem] {
        let titles = Dictionary(model.sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let subscribed = Set(model.sources.filter(\.isSubscribed).map(\.id))
        let all = model.episodes
            .filter { subscribed.contains($0.key) }
            .flatMap(\.value)
            .filter(model.canPlay)
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        return all.prefix(rowLimit).map { episode in
            episodeItem(episode, subtitle: titles[episode.sourceID])
        }
    }

    private func queueItems() -> [CPListItem] {
        let titles = Dictionary(model.sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return model.upNext.prefix(rowLimit).map { episode in
            episodeItem(episode, subtitle: titles[episode.sourceID])
        }
    }

    /// Eine Zeile für eine Folge. Antippen spielt sie: das ist die Handlung
    /// im Auto, die Regel 1 verlangt.
    private func episodeItem(_ episode: Episode, subtitle: String?) -> CPListItem {
        var parts: [String] = []
        if let subtitle { parts.append(subtitle) }
        if let length = episode.declaredDuration?.seconds, length > 0 {
            parts.append(Duration.seconds(Int(length / 60) * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2)))
        }
        let item = CPListItem(text: episode.title, detailText: parts.joined(separator: " · "))
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.play(episode)
                completion()
            }
        }
        loadArtwork(for: item, url: episode.artworkURL ?? model.sources.first { $0.id == episode.sourceID }?.artworkURL)
        return item
    }

    private func openShow(_ show: Source) async {
        if (model.episodes[show.id] ?? []).isEmpty { await model.loadEpisodes(for: show.id) }
        let episodes = (model.episodes[show.id] ?? [])
            .filter(model.canPlay)
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let items = episodes.prefix(rowLimit).map { episodeItem($0, subtitle: nil) }
        let template = CPListTemplate(title: show.title, sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = [String(localized: "Keine Folgen", table: "CarPlay")]
        _ = try? await interface.pushTemplate(template, animated: true)
    }

    // MARK: - Spielen

    private func play(_ episode: Episode) {
        model.episodePlayer.ignoresRemotePlayUntil = nil
        model.playEpisode(episode)
        showNowPlaying()
    }

    private func showNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        if interface.topTemplate === template { return }
        Task { _ = try? await interface.pushTemplate(template, animated: true) }
    }

    private static let rates: [Float] = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0]

    private func cycleRate() {
        let player = model.episodePlayer
        guard let index = Self.rates.firstIndex(where: { abs($0 - player.rate) < 0.01 }) else {
            player.rate = 1.0
            return
        }
        player.rate = Self.rates[(index + 1) % Self.rates.count]
    }

    // MARK: - CPNowPlayingTemplateObserver

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            let items = queueItems()
            let template = CPListTemplate(title: String(localized: "Als Nächstes", table: "CarPlay"), sections: [CPListSection(items: items)])
            template.emptyViewTitleVariants = [String(localized: "Nichts in der Warteschlange", table: "CarPlay")]
            _ = try? await interface.pushTemplate(template, animated: true)
        }
    }

    // MARK: - Cover

    private func loadArtwork(for item: CPListItem, url: URL?) {
        guard let url else { return }
        let side = max(CPListItem.maximumImageSize.width, 1)
        let pixels = Int(side * UITraitCollection.current.displayScale)
        Task { @MainActor [weak item] in
            let key = ArtworkThumbnails.Key(url: url, pixels: pixels, revision: 0)
            guard let image = await ArtworkThumbnails.shared.image(for: key) else { return }
            item?.setImage(UIImage(cgImage: image))
        }
    }
}
