//
//  AppModel+YouTube.swift
//  PodcastAI
//
//  Transkripte für YouTube-Folgen.
//
//  YouTube liefert der App keinen Ton, und die App lädt ihn auch nicht über
//  Umwege. Ein Transkript gibt es trotzdem, in dieser Reihenfolge:
//
//  1. Vorhandene Untertitel des Videos über Supadata, wenn der Nutzer einen
//     eigenen Schlüssel eingetragen hat. Supadata ist ein unabhängiger
//     Dienst; er bekommt dafür die Adresse des Videos, sonst nichts.
//  2. Sonst die passende Folge des Audio-Podcasts desselben Kanals, falls
//     er abonniert ist. Deren Ton wird wie immer auf dem Gerät transkribiert.
//  3. Sonst Titel, Beschreibung und Kapitel, mit einem ruhigen Satz, warum.
//
//  Die Reihenfolge selbst steht in `YouTubeTranscriptPlanner` (Paket), hier
//  nur, was die App dafür weiß: Schlüssel, Schalter, Abos und Fehlversuche.
//  Stellen aus Videos spielt nicht die App; ein Tipp öffnet das Video bei
//  YouTube an der Stelle. Von selbst öffnet sich nichts.
//

import Foundation
import PodcastAIKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension AppModel {

    // MARK: - Welche Folgen

    /// Eine Folge ohne Ton, deren Webseite ein YouTube-Video ist.
    func isYouTubeVideo(_ episode: Episode) -> Bool {
        episode.audioURL == nil && YouTubeLinks.videoID(in: episode.webPageURL) != nil
    }

    /// Die Adresse des Videos ohne Anhängsel. An ihr hängt die Medienfassung.
    func watchURL(of episode: Episode) -> URL? {
        YouTubeLinks.canonicalWatchURL(for: episode.webPageURL)
    }

    /// Die Adresse eines Beitrags von TikTok, Instagram, X oder Facebook.
    func socialPostURL(of episode: Episode) -> URL? {
        guard episode.audioURL == nil, let page = episode.webPageURL,
              case .post(_, let url)? = SocialLinks.classify(page) else { return nil }
        return url
    }

    /// Ein Video ohne Ton, dessen Untertitel Supadata holen kann: YouTube
    /// oder ein einzelner Beitrag aus einem sozialen Netz.
    func isCaptionVideo(_ episode: Episode) -> Bool {
        isYouTubeVideo(episode) || socialPostURL(of: episode) != nil
    }

    /// Die Adresse, die an Supadata geht und an der die Medienfassung hängt.
    func captionURL(of episode: Episode) -> URL? {
        guard episode.audioURL == nil else { return nil }
        return watchURL(of: episode) ?? socialPostURL(of: episode)
    }

    /// Kann die App für diese Folge ein Transkript erstellen? Mit Ton immer,
    /// bei YouTube nur, wenn Supadata gerade gefragt werden darf.
    func canTranscribe(_ episode: Episode, byHand: Bool = true) -> Bool {
        if episode.audioURL != nil { return true }
        guard isCaptionVideo(episode) else { return false }
        return YouTubeTranscriptPlanner.captionGap(youTubeInputs(for: episode, byHand: byHand)) == nil
    }

    /// Darf das Vorbereiten von selbst YouTube-Videos dieses Kanals nehmen?
    /// Nur, was für den ganzen Kanal gilt: Schlüssel, Schalter, Ablehnung,
    /// Ruhe des Dienstes. Die Wartezeit eines einzelnen gescheiterten Videos
    /// prüft `isOpenForPreparation`. Stünde sie hier, fiele ein Video aus
    /// dem Fenster der neuesten, das nächstältere rückte nach, und bei jedem
    /// Aktualisieren ginge eine Anfrage mehr an Supadata.
    func allowsAutomaticCaptions(_ episode: Episode) -> Bool {
        guard isCaptionVideo(episode) else { return false }
        var inputs = youTubeInputs(for: episode, byHand: false)
        inputs.lastFailure = nil
        return YouTubeTranscriptPlanner.captionGap(inputs) == nil
    }

    /// Ist ein Video nach einem Fehlversuch noch in seiner Wartezeit?
    func captionsCoolingDown(_ id: EpisodeID, now: Date = Date()) -> Bool {
        captionFailures[id.rawValue].map { now < $0.retryAt } ?? false
    }

    // MARK: - Reihenfolge

    /// Was die Reihenfolge für diese Folge wissen muss.
    func youTubeInputs(for episode: Episode, byHand: Bool, now: Date = Date()) -> YouTubeTranscriptPlanner.Inputs {
        let counterparts = podcastCounterparts[episode.sourceID] ?? []
        return YouTubeTranscriptPlanner.Inputs(
            switchedOn: youTubeCaptionsEnabled,
            hasKey: hasSupadataKey,
            keyRejected: supadataKeyRejected,
            serviceResting: supadataRestingUntil.map { now < $0 } ?? false,
            lastFailure: captionFailures[episode.id.rawValue],
            requestedByHand: byHand,
            matchingAudioEpisode: matchingAudioEpisode(for: episode)?.id,
            hasCounterpartPodcast: !counterparts.isEmpty,
            now: now)
    }

    func youTubeRoute(for episode: Episode, byHand: Bool) -> YouTubeTranscriptRoute {
        YouTubeTranscriptPlanner.route(youTubeInputs(for: episode, byHand: byHand))
    }

    /// Die Folge eines abonnierten Audio-Podcasts, die dasselbe ist wie das
    /// Video. Gesucht wird in den Podcasts, die zum Kanal passen, und, falls
    /// die Suche im Verzeichnis nichts fand, in Podcasts mit demselben Titel
    /// wie der Kanal.
    func matchingAudioEpisode(for episode: Episode) -> Episode? {
        let feeds = Set((podcastCounterparts[episode.sourceID] ?? []).map { Self.feedKey($0.feedURL) })
        let channelTitle = sources.first { $0.id == episode.sourceID }?.title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let podcasts = sources.filter { source in
            guard source.kind == .podcastRSS, source.id != episode.sourceID else { return false }
            if let feed = source.feedURL, feeds.contains(Self.feedKey(feed)) { return true }
            guard let channelTitle, !channelTitle.isEmpty else { return false }
            return source.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == channelTitle
        }
        guard !podcasts.isEmpty else { return nil }
        let candidates = podcasts.flatMap { episodes[$0.id] ?? [] }
        return CounterpartEpisodeMatcher.match(videoTitle: episode.title, videoPublished: episode.publishedAt,
                                               in: candidates)
    }

    /// Feed-Adressen vergleichbar machen: Schema, `www.` und Schrägstrich egal.
    static func feedKey(_ url: URL) -> String {
        var host = url.host()?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path + (url.query().map { "?" + $0 } ?? "")
    }

    // MARK: - Hinweis in der Folge

    /// Ein ruhiger Satz, warum eine YouTube-Folge (noch) kein Transkript hat,
    /// oder `nil`, wenn es sich erstellen lässt.
    ///
    /// Gelesen wie beim Vorbereiten, also mit dem letzten Fehlversuch: hat
    /// das Video keine Untertitel, steht das hier, auch nach einem Neustart.
    /// Von Hand geht es trotzdem, über „Transkript erstellen“ im Menü.
    /// Nach einem vorübergehenden Fehler steht kein Satz hier; dann zeigt
    /// die Folge den Fehler mit „Erneut versuchen“.
    func youTubeTranscriptHint(for episode: Episode) -> String? {
        let route = youTubeRoute(for: episode, byHand: false)
        switch route {
        case .captions:
            return nil
        case .counterpartEpisode(let id, _):
            let title = episodes.values.lazy.flatMap { $0 }.first { $0.id == id }?.title ?? ""
            return String(localized: """
                Das Transkript entsteht aus der passenden Folge des Audio-Podcasts, „\(title)“. \
                Dort gibt es auch Fakten und den Chat.
                """)
        case .offerCounterpartPodcast(.coolingDown), .metadataOnly(.coolingDown):
            return nil
        case .offerCounterpartPodcast(let gap):
            return Self.gapSentence(gap) + " " + String(localized: """
                Zu diesem Kanal gibt es einen Audio-Podcast. Abonniert, liefert er Transkripte aus dem Ton.
                """)
        case .metadataOnly(let gap):
            return Self.gapSentence(gap)
        }
    }

    /// Braucht die Folge einen Schlüssel, damit es ein Transkript gibt? Dann
    /// zeigt sie den Weg in die Einstellungen.
    func youTubeHintNeedsKey(_ episode: Episode) -> Bool {
        guard isCaptionVideo(episode) else { return false }
        return YouTubeTranscriptPlanner.captionGap(youTubeInputs(for: episode, byHand: true)) == .noKey
    }

    static func gapSentence(_ gap: YouTubeTranscriptGap) -> String {
        switch gap {
        case .noKey:
            String(localized: """
                Zu diesem Video gibt es hier Titel, Beschreibung und Kapitel. Mit eigenem \
                Supadata-Schlüssel gibt es hier ein Transkript.
                """)
        case .keyRejected:
            String(localized: """
                Supadata hat den eingetragenen Schlüssel abgelehnt. Bis du in den Einstellungen einen \
                neuen einträgst, holt die App keine Untertitel.
                """)
        case .switchedOff:
            String(localized: """
                „YouTube-Transkripte über Supadata“ ist in den Einstellungen aus. Es gibt hier Titel, \
                Beschreibung und Kapitel.
                """)
        case .serviceResting:
            String(localized: """
                Supadata nimmt gerade keine Anfragen an, etwa weil das Kontingent aufgebraucht ist. \
                Die App versucht es später wieder.
                """)
        case .noCaptions:
            String(localized: "Zu diesem Video gibt es keine Untertitel. Es gibt hier Titel, Beschreibung und Kapitel.")
        case .coolingDown:
            String(localized: "Die Untertitel ließen sich gerade nicht holen. Die App versucht es später wieder.")
        }
    }

    // MARK: - Schlüssel

    /// Speichert einen neuen Schlüssel im Schlüsselbund und prüft ihn gleich.
    func saveSupadataKey(_ key: String) async {
        guard SupadataKeychain.save(key) else {
            supadataKeyCheck = .idle
            lastError = String(localized: "Der Schlüssel ließ sich im Schlüsselbund nicht sichern.")
            return
        }
        hasSupadataKey = true
        supadataKeyRejected = false
        supadataRestingUntil = nil
        // Ein neuer Schlüssel hat eine neue Chance, auch bei Videos, die mit
        // dem alten scheiterten.
        captionFailures = captionFailures.filter { $0.value.kind == .lasting }
        await supadata.resetBreaker()
        await checkSupadataKey()
        youTubeCaptionConditionsChanged()
    }

    /// Entfernt den Schlüssel. Danach fragt die App Supadata nie mehr.
    func removeSupadataKey() async {
        SupadataKeychain.delete()
        hasSupadataKey = false
        supadataKeyRejected = false
        supadataRestingUntil = nil
        supadataKeyCheck = .idle
        await supadata.resetBreaker()
        youTubeCaptionConditionsChanged()
    }

    /// Eine günstige Probe über `GET /me`. Kostet keine Untertitel.
    func checkSupadataKey() async {
        guard let key = SupadataKeychain.read() else {
            supadataKeyCheck = .idle
            return
        }
        supadataKeyCheck = .checking
        do {
            let account = try await supadata.account(apiKey: key)
            supadataKeyRejected = false
            if account.isExhausted {
                supadataKeyCheck = .exhausted
            } else {
                supadataKeyCheck = .valid(used: account.usedCredits, max: account.maxCredits)
                supadataRestingUntil = nil
            }
        } catch .unauthorized {
            supadataKeyRejected = true
            supadataKeyCheck = .rejected
            youTubeCaptionConditionsChanged()
        } catch .quota {
            supadataKeyCheck = .exhausted
        } catch {
            supadataKeyCheck = .unreachable
        }
    }

    /// Schalter, Schlüssel oder Dienst haben sich geändert: was von selbst
    /// wartet und nicht mehr darf, fällt heraus, und neue Folgen kommen dazu.
    func youTubeCaptionConditionsChanged() {
        dropYouTubeItemsThatCannotRun()
        Task { await prepareNewEpisodes() }
    }

    // MARK: - Fehlversuche

    static func loadCaptionFailures() -> [String: CaptionFailure] {
        guard let data = UserDefaults.standard.data(forKey: captionFailuresKey),
              let decoded = try? JSONDecoder().decode([String: CaptionFailure].self, from: data) else { return [:] }
        return decoded
    }

    static func saveCaptionFailures(_ failures: [String: CaptionFailure]) {
        // Nur die jüngsten 2.000 Folgen. Ein totes Archiv hat viele.
        let kept = failures.count <= 2_000 ? failures
            : Dictionary(uniqueKeysWithValues: failures.sorted { $0.value.at > $1.value.at }.prefix(2_000).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: captionFailuresKey)
        }
    }

    // MARK: - Metadaten über Supadata

    /// Darf die App Supadata gerade fragen? Schlüssel da, nicht abgelehnt,
    /// Schalter an und der Dienst nicht in Ruhe.
    var allowsSupadataRequests: Bool {
        hasSupadataKey && !supadataKeyRejected && youTubeCaptionsEnabled
            && !(supadataRestingUntil.map { Date() < $0 } ?? false)
    }

    /// Unter dieser Adresse liegen die Metadaten einer Folge.
    func metadataKey(for episode: Episode) -> String? {
        if let video = captionURL(of: episode) { return video.absoluteString }
        guard SupadataEnrichment.supports(episode.webPageURL) else { return nil }
        return episode.webPageURL?.absoluteString
    }

    /// Die Metadaten einer Folge, falls schon geholt.
    func supadataMetadata(for episode: Episode) -> SupadataMetadata? {
        metadataKey(for: episode).flatMap { supadataMetadata[$0] }
    }

    /// Die Folge mit den Lücken, die Supadata füllen konnte. Ohne Metadaten
    /// unverändert. Was der Feed sagt, bleibt.
    func withSupadataMetadata(_ episode: Episode) -> Episode {
        guard let metadata = supadataMetadata(for: episode) else { return episode }
        return SupadataEnrichment.enrich(episode, with: metadata)
    }

    func withSupadataMetadata(_ list: [Episode]) -> [Episode] {
        guard !supadataMetadata.isEmpty else { return list }
        return list.map(withSupadataMetadata)
    }

    /// Kanäle bekommen Anbieter und Bild aus den Metadaten eines ihrer
    /// Videos, wenn der Feed sie nicht nennt.
    func withSupadataMetadata(sources list: [Source]) -> [Source] {
        guard !supadataMetadata.isEmpty else { return list }
        return list.map { source in
            guard source.kind == .youTubeChannel,
                  (source.author?.isEmpty ?? true) || source.artworkURL == nil,
                  let metadata = (episodes[source.id] ?? []).lazy.compactMap(supadataMetadata(for:)).first
            else { return source }
            return SupadataEnrichment.enrich(source, with: metadata)
        }
    }

    /// Holt fehlende Metadaten der neuesten Folgen im Hintergrund, eine nach
    /// der anderen. Nach denselben Regeln fürs Netz wie das Vorbereiten, und
    /// nie für mehr als die gewählte Zahl Folgen je Kanal.
    func fetchMissingMetadata() {
        guard metadataTask == nil, allowsSupadataRequests, preparationWait == nil else { return }
        let now = Date()
        let wanted = sources.flatMap { source in
            (episodes[source.id] ?? [])
                .filter { SupadataEnrichment.supports($0.webPageURL) }
                .prefix(episodesPerSource)
                .filter { episode in
                    guard let key = metadataKey(for: episode), supadataMetadata[key] == nil,
                          SupadataEnrichment.wantsMetadata(episode) else { return false }
                    return metadataFailures[key].map { now >= $0.retryAt } ?? true
                }
        }
        guard !wanted.isEmpty else { return }
        metadataTask = Task { [weak self] in
            for episode in wanted {
                guard let self, !Task.isCancelled, self.allowsSupadataRequests,
                      self.preparationWait == nil else { break }
                await self.loadMetadata(for: episode)
            }
            self?.metadataTask = nil
        }
    }

    /// Beim Öffnen einer Folge: fehlen ihr Beschreibung, Länge oder Bild,
    /// holt die App die Metadaten gleich. Klein genug für jedes Netz, aber
    /// nicht ohne Zustimmung über Mobilfunk.
    func requestMetadata(for episode: Episode) {
        guard allowsSupadataRequests, !isOffline, !mobileDataNeedsConsent,
              let key = metadataKey(for: episode), supadataMetadata[key] == nil,
              SupadataEnrichment.wantsMetadata(episode),
              metadataFailures[key].map({ Date() >= $0.retryAt }) ?? true else { return }
        Task { await loadMetadata(for: episode) }
    }

    /// Ein Abruf. Nie blockierend: Fehler merkt sich die App, sonst nichts.
    private func loadMetadata(for episode: Episode) async {
        guard let key = metadataKey(for: episode), let url = URL(string: key),
              let apiKey = SupadataKeychain.read() else { return }
        do {
            let metadata = try await supadata.metadata(for: url, apiKey: apiKey)
            supadataMetadata[key] = metadata
            Self.saveSupadataMetadata(supadataMetadata)
            metadataFailures[key] = nil
            // Die Liste im Speicher zeigt die gefüllten Lücken gleich.
            if var list = episodes[episode.sourceID],
               let index = list.firstIndex(where: { $0.id == episode.id }) {
                list[index] = withSupadataMetadata(list[index])
                episodes[episode.sourceID] = list
            }
            sources = withSupadataMetadata(sources: sources)
            metadataRevision += 1
        } catch {
            metadataFailures[key] = CaptionFailure(error: error, at: Date())
            switch error {
            case .unauthorized:
                supadataKeyRejected = true
                supadataKeyCheck = .rejected
                dropYouTubeItemsThatCannotRun()
            case .quota, .rateLimited:
                if case .open(_, let until) = await supadata.breaker {
                    supadataRestingUntil = until
                }
            default:
                break
            }
        }
    }

    private static var metadataCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "supadata-metadata.json")
    }

    static func loadSupadataMetadata() -> [String: SupadataMetadata] {
        guard let url = metadataCacheURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SupadataMetadata].self, from: data) else { return [:] }
        return decoded
    }

    static func saveSupadataMetadata(_ metadata: [String: SupadataMetadata]) {
        guard let url = metadataCacheURL else { return }
        // Höchstens 2.000 Videos; reicht für viele Kanäle, bleibt klein.
        let kept = metadata.count <= 2_000 ? metadata : Dictionary(uniqueKeysWithValues: metadata.prefix(2_000).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(kept) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: - Im Video an der Stelle

    /// Öffnet das Video bei YouTube an einer Stelle. Nur aus einem Tipp.
    func openInYouTube(videoID: String, at time: MediaTime?) {
        guard let url = YouTubeLinks.watchURL(videoID: videoID, at: time) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Öffnet eine Adresse im Browser oder in der App der Plattform.
    func openExternally(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Öffnet die Folge dort, wo sie liegt, falls sie ein Video ohne Ton ist:
    /// YouTube an der Stelle, andere Beiträge am Anfang. `true`, wenn geöffnet.
    @discardableResult
    func openExternally(_ episode: Episode, at seconds: Double?) -> Bool {
        guard episode.audioURL == nil else { return false }
        if let videoID = YouTubeLinks.videoID(in: episode.webPageURL) {
            openInYouTube(videoID: videoID, at: seconds.map { MediaTime(seconds: $0) })
            return true
        }
        guard let post = socialPostURL(of: episode) else { return false }
        openExternally(post)
        return true
    }
}
