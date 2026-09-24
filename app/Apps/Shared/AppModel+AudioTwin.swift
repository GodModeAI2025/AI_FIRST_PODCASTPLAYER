//
//  AppModel+AudioTwin.swift
//  PodcastAI
//
//  Untertitel des YouTube-Zwillings für Folgen mit Ton.
//
//  Hat eine Folge kein eigenes Transkript vom Podcast und ist ein eigener
//  Supadata-Schlüssel eingetragen, versucht die App vor dem Download die
//  Untertitel derselben Folge auf YouTube. Die Reihenfolge und die Regeln
//  stehen in `AudioTwinPlanner` und `AudioTwinMatcher` (Paket), der Abgleich
//  der Zeiten in `ContentPipeline`. Hier steht, was die App dafür weiß:
//  Schlüssel, Netz, abonnierte Kanäle, frühere Versuche.
//
//  Was an Supadata geht: bei einer Suche der Titel des Podcasts und der
//  Folge, sonst die Adresse des Videos. Ohne Schlüssel nichts.
//
//  Scheitert irgendein Schritt, lädt die App den Ton und transkribiert ihn
//  selbst. Nichts davon hält die Warteschlange länger auf als die Frist des
//  Clients.
//

import Foundation
import PodcastAIKit

extension AppModel {

    // MARK: - Den Zwilling finden

    /// Die abonnierten YouTube-Kanäle, die zu diesem Podcast gehören: laut
    /// Verzeichnis sein Gegenstück oder mit demselben Namen.
    func linkedYouTubeChannels(for podcast: Source) -> [Source] {
        let podcastFeed = podcast.feedURL.map(Self.feedKey)
        let podcastTitle = podcast.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return sources.filter { channel in
            guard channel.kind == .youTubeChannel, channel.id != podcast.id else { return false }
            if let podcastFeed,
               (podcastCounterparts[channel.id] ?? []).contains(where: { Self.feedKey($0.feedURL) == podcastFeed }) {
                return true
            }
            return !podcastTitle.isEmpty
                && channel.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == podcastTitle
        }
    }

    /// Das Video aus einem abonnierten Kanal, das dieselbe Folge ist. Kostet
    /// nichts, die Videos liegen schon in der Bibliothek.
    func subscribedTwin(for episode: Episode) -> Episode? {
        guard let podcast = sources.first(where: { $0.id == episode.sourceID }) else { return nil }
        let channels = linkedYouTubeChannels(for: podcast)
        guard !channels.isEmpty else { return nil }
        let videos = channels.flatMap { episodes[$0.id] ?? [] }
            .filter { $0.audioURL == nil && YouTubeLinks.videoID(in: $0.webPageURL) != nil }
        return AudioTwinMatcher.fromChannel(episode: episode, videos: videos,
                                            ignoring: [podcast.title] + channels.map(\.title))
    }

    /// Darf die Folge jetzt ins Netz, für Supadata und die Stücke des Tons?
    /// Von selbst Eingereihtes nur nach den Regeln fürs Vorbereiten, von Hand
    /// Angefordertes nicht ohne Zustimmung im Mobilfunk, ohne Netz nie. Liegt
    /// der Ton schon auf dem Gerät, läuft die Folge auch ohne diese Freigabe;
    /// dann gibt es eben keinen Zwilling.
    func twinNetworkAllowed(automatic: Bool) -> Bool {
        guard !isOffline else { return false }
        return automatic ? preparationWait == nil : !mobileDataNeedsConsent
    }

    /// Schritt 2 für diese Folge, oder `nil`, wenn er entfällt: ohne
    /// Schlüssel, ohne erlaubtes Netz, in der Wartezeit nach einem Versuch
    /// oder ohne Weg zu einem Zwilling.
    func twinCaptionHook(for episode: Episode) -> TwinCaptionHook? {
        guard episode.audioURL != nil,
              let podcast = sources.first(where: { $0.id == episode.sourceID }) else { return nil }
        let automatic = isQueuedAutomatically(episode.id)
        let record = audioTwinRecords[episode.id.rawValue]
        let subscribed = subscribedTwin(for: episode)
        let inputs = AudioTwinPlanner.Inputs(
            hasPublisherTranscript: episode.timedTranscriptURL != nil,
            supadataAllowed: allowsSupadataRequests,
            networkAllowed: twinNetworkAllowed(automatic: automatic),
            record: record,
            subscribedTwinVideoID: subscribed.flatMap { YouTubeLinks.videoID(in: $0.webPageURL) },
            searchQuery: AudioTwinMatcher.searchQuery(podcastTitle: podcast.title, episodeTitle: episode.title))
        guard let plan = AudioTwinPlanner.twinSource(inputs), let key = SupadataKeychain.read() else { return nil }

        let client = supadata
        let episodeID = episode.id
        let podcastID = podcast.id.rawValue
        let podcastTitle = podcast.title
        let podcastAuthor = podcast.author
        let preferredChannel = audioTwinChannels[podcastID]
        // Untertitel in der Sprache der Folge, nicht in der der App: nur sie
        // passen zum Ton.
        let language = transcriptionLocale(for: episode).language.languageCode?.identifier
        let preferred = [language].compactMap { $0 }

        return TwinCaptionHook(
            provide: { [weak self] episode in
                do {
                    let videoID: String
                    var channelID: String?
                    switch plan {
                    case .subscribedChannel(let id):
                        videoID = id
                    case .rememberedVideo(let id):
                        videoID = id
                        channelID = record?.channelID
                    case .search(let query):
                        let results = try await client.searchVideos(query, apiKey: key)
                        await self?.noteTwinSearch(episodeID)
                        guard let match = AudioTwinMatcher.fromSearch(
                            episode: episode, podcastTitle: podcastTitle, podcastAuthor: podcastAuthor,
                            results: results, preferredChannelID: preferredChannel) else {
                            await self?.noteTwinFailure(episodeID, kind: .lasting)
                            return nil
                        }
                        videoID = match.id
                        channelID = match.channelID
                    }
                    await self?.noteTwinVideo(episodeID, videoID: videoID, channelID: channelID)
                    guard let url = SourceResolver.watchURL(videoID: videoID) else { return nil }
                    let captions = try await client.transcript(videoURL: url, apiKey: key,
                                                               preferredLanguages: preferred)
                    return TwinCaptions(captions: captions, videoID: videoID, channelID: channelID)
                } catch {
                    let failure = (error as? SupadataError) ?? (error is CancellationError ? .cancelled : .network)
                    await self?.noteTwinError(failure, for: episodeID)
                    return nil
                }
            },
            report: { [weak self] id, twin, outcome in
                Task { @MainActor in self?.noteTwinOutcome(outcome, twin: twin, for: id, podcastID: podcastID) }
            })
    }

    // MARK: - Merken

    private func noteTwinSearch(_ id: EpisodeID) {
        var record = audioTwinRecords[id.rawValue] ?? AudioTwinRecord()
        record.searchedAt = Date()
        audioTwinRecords[id.rawValue] = record
    }

    private func noteTwinVideo(_ id: EpisodeID, videoID: String, channelID: String?) {
        var record = audioTwinRecords[id.rawValue] ?? AudioTwinRecord()
        record.videoID = videoID
        if let channelID { record.channelID = channelID }
        audioTwinRecords[id.rawValue] = record
    }

    private func noteTwinFailure(_ id: EpisodeID, kind: CaptionFailure.Kind) {
        var record = audioTwinRecords[id.rawValue] ?? AudioTwinRecord()
        record.failure = CaptionFailure(kind: kind, at: Date())
        audioTwinRecords[id.rawValue] = record
    }

    /// Supadata oder das Netz scheiterten. Ein Abbruch ist kein Fehlschlag.
    private func noteTwinError(_ error: SupadataError, for id: EpisodeID) async {
        guard error != .cancelled else { return }
        noteTwinFailure(id, kind: error.isTransient ? .passing : .lasting)
        await noteSupadataAccountError(error)
    }

    /// Wie der Abgleich ausging. Gelungen: der Kanal gilt für diesen Podcast
    /// künftig als vertraut. Sonst eine Woche Ruhe für diese Folge, denn
    /// dieselben Untertitel passten auch beim nächsten Mal nicht.
    private func noteTwinOutcome(_ outcome: TwinAlignmentOutcome, twin: TwinCaptions, for id: EpisodeID,
                                 podcastID: String) {
        var record = audioTwinRecords[id.rawValue] ?? AudioTwinRecord()
        switch outcome {
        case .aligned:
            record.failure = nil
            if let channel = twin.channelID { audioTwinChannels[podcastID] = channel }
        case .languageMismatch, .unsupportedAudio, .notAligned:
            record.failure = CaptionFailure(kind: .lasting, at: Date())
        }
        audioTwinRecords[id.rawValue] = record
    }

    /// Fehler, die den Schlüssel oder das Konto betreffen, gelten für jede
    /// Folge: abgelehnt, Kontingent aufgebraucht, gedrosselt.
    func noteSupadataAccountError(_ failure: SupadataError) async {
        switch failure {
        case .unauthorized:
            // Aus, bis jemand einen neuen Schlüssel einträgt. Die Einstellungen sagen es.
            supadataKeyRejected = true
            supadataKeyCheck = .rejected
            dropYouTubeItemsThatCannotRun()
        case .quota, .rateLimited:
            if case .open(_, let until) = await supadata.breaker {
                supadataRestingUntil = until ?? Date().addingTimeInterval(supadata.configuration.rateLimitCooldown)
            }
            if supadataRestingUntil != nil { dropYouTubeItemsThatCannotRun() }
        case .missingKey:
            hasSupadataKey = SupadataKeychain.hasKey
            dropYouTubeItemsThatCannotRun()
        default:
            break
        }
    }

    // MARK: - Speichern

    static func loadAudioTwinRecords() -> [String: AudioTwinRecord] {
        guard let data = UserDefaults.standard.data(forKey: audioTwinRecordsKey),
              let decoded = try? JSONDecoder().decode([String: AudioTwinRecord].self, from: data) else { return [:] }
        return decoded
    }

    static func saveAudioTwinRecords(_ records: [String: AudioTwinRecord]) {
        // Nur die jüngsten 2.000 Folgen, nach dem letzten Ereignis.
        func latest(_ record: AudioTwinRecord) -> Date {
            max(record.searchedAt ?? .distantPast, record.failure?.at ?? .distantPast)
        }
        let kept = records.count <= 2_000 ? records
            : Dictionary(uniqueKeysWithValues: records.sorted { latest($0.value) > latest($1.value) }
                .prefix(2_000).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: audioTwinRecordsKey)
        }
    }
}
