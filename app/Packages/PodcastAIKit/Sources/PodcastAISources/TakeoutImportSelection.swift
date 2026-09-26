//
//  TakeoutImportSelection.swift
//  PodcastAISources
//
//  Die Liste zum Abhaken nach dem Import der YouTube-Abos: je Kanal, ob es
//  einen passenden Audio-Podcast gibt, was abonniert werden soll und was
//  schon abonniert ist. Empfohlen ist der Audio-Podcast, denn nur mit Ton
//  gibt es Transkript, Fakten und Tags.
//
//  Hier fällt keine Entscheidung ohne den Nutzer. Das Modell schlägt vor,
//  wer auswählt, bestimmt. Nichts davon startet Ton.
//

import Foundation

// MARK: - Passender Audio-Podcast

/// Ordnet Treffer aus Apples Podcast-Verzeichnis einem Kanalnamen zu.
///
/// Dieselbe Regel wie bei einem einzelnen YouTube-Kanal (`PodcastCounterpart`
/// in der App): Name des Kanals im Titel oder beim Autor des Podcasts. Hier
/// zählen nur ganze Wörter, weil bei 80 Kanälen sonst „Nat“ zu „National“
/// passte, und die Treffer kommen geordnet: gleicher Titel vor gleichem
/// Autor vor einem Titel, der den Namen enthält.
public enum ChannelCounterpartRanking {

    /// Mehr als drei Möglichkeiten je Kanal liest niemand in einer Liste.
    public static let maximumCandidates = 3
    /// Kürzere Namen treffen fast alles. Für sie sucht die App nicht.
    public static let minimumNameLength = 3

    /// Sucht die App für diesen Namen im Verzeichnis?
    public static func isSearchable(_ name: String) -> Bool {
        normalized(name).count >= minimumNameLength
    }

    /// Passende Podcasts, der beste zuerst, höchstens `limit`.
    public static func ranked(
        _ results: [CatalogPodcast], forChannel name: String, limit: Int = maximumCandidates
    ) -> [CatalogPodcast] {
        let needle = normalized(name)
        guard needle.count >= minimumNameLength else { return [] }
        let compactNeedle = needle.replacingOccurrences(of: " ", with: "")
        var seen = Set<String>()
        let scored = results.enumerated().compactMap { offset, podcast -> (rank: Int, offset: Int, podcast: CatalogPodcast)? in
            guard seen.insert(CatalogMerge.feedKey(podcast.feedURL)).inserted else { return nil }
            let title = normalized(podcast.title)
            let author = normalized(podcast.author)
            let rank: Int
            if title == needle || title.replacingOccurrences(of: " ", with: "") == compactNeedle {
                rank = 0
            } else if author == needle || author.replacingOccurrences(of: " ", with: "") == compactNeedle {
                rank = 1
            } else if containsWords(needle, in: title) {
                rank = 2
            } else if containsWords(needle, in: author) {
                rank = 3
            } else {
                return nil
            }
            return (rank, offset, podcast)
        }
        return scored
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .prefix(max(0, limit))
            .map(\.podcast)
    }

    /// Kleinbuchstaben ohne Akzente, Satzzeichen als Leerzeichen, jedes
    /// Wort durch genau ein Leerzeichen getrennt.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func containsWords(_ needle: String, in haystack: String) -> Bool {
        " \(haystack) ".contains(" \(needle) ")
    }
}

// MARK: - Tempo der Suche

/// Wie schnell die App nacheinander im Verzeichnis sucht.
///
/// Apple bremst zu schnelle Suchen mit 403 und nennt etwa 20 Anfragen je
/// Minute als Grenze. Die ersten Kanäle gehen deshalb zügig, danach alle
/// drei Sekunden eine Suche. Meldet Apple doch „zu viele Anfragen“, wartet
/// die App eine Minute und bleibt danach beim langsamen Tempo.
public struct DirectorySearchPace: Sendable, Equatable {

    public let burst: Int
    public let quickInterval: TimeInterval
    public let interval: TimeInterval
    public let coolDown: TimeInterval

    private var sent = 0
    private var lastStart: Date?
    private var resumeAt: Date?

    public init(burst: Int = 8, quickInterval: TimeInterval = 0.25,
                interval: TimeInterval = 3, coolDown: TimeInterval = 60) {
        self.burst = burst
        self.quickInterval = quickInterval
        self.interval = interval
        self.coolDown = coolDown
    }

    /// Sekunden bis zur nächsten Suche. Die Suche zählt damit als gestellt.
    public mutating func delay(before now: Date) -> TimeInterval {
        let spacing = sent < burst ? quickInterval : interval
        var start = lastStart.map { max(now, $0.addingTimeInterval(spacing)) } ?? now
        if let resumeAt, resumeAt > start { start = resumeAt }
        sent += 1
        lastStart = start
        return start.timeIntervalSince(now)
    }

    /// Apple hat „zu viele Anfragen“ gemeldet.
    public mutating func noteRateLimited(at now: Date) {
        resumeAt = now.addingTimeInterval(coolDown)
        sent = max(sent, burst)
    }
}

// MARK: - Auswahl

/// Was aus der Abo-Liste abonniert werden soll.
public struct TakeoutImportSelection: Sendable, Equatable {

    /// Stand der Suche nach einem Audio-Podcast für einen Kanal.
    public enum Lookup: Sendable, Equatable {
        case pending
        /// Passende Podcasts, der beste zuerst. Nie leer.
        case found([CatalogPodcast])
        case nothing
        case failed
        /// Die Suche wurde vorher beendet.
        case skipped
    }

    /// Was für einen Kanal abonniert wird.
    public enum Target: Sendable, Hashable {
        case audioPodcast(URL)
        case youTubeChannel
    }

    /// Ein Abo, das beim Abonnieren entsteht. Führen mehrere Kanäle zum
    /// selben Audio-Podcast, wird er einmal abonniert.
    public struct Subscription: Sendable, Hashable, Identifiable {
        public let feedURL: URL
        public let title: String
        public let isAudioPodcast: Bool
        public internal(set) var channelIDs: [String]
        public var id: String { CatalogMerge.feedKey(feedURL) }
    }

    public let channels: [TakeoutChannel]
    public private(set) var lookups: [String: Lookup]
    public private(set) var selected: Set<String> = []
    /// Hat jemand selbst ausgewählt? Bis dahin wählt das Modell jeden Kanal
    /// mit Audio-Podcast von selbst aus, sobald die Suche ihn findet.
    public private(set) var hasUserChanges = false
    private var choices: [String: Target] = [:]
    private var subscribedKeys: Set<String>
    private let channelsByID: [String: TakeoutChannel]

    public init(channels: [TakeoutChannel], subscribedFeeds: some Sequence<URL>) {
        self.channels = channels
        self.lookups = Dictionary(channels.map { ($0.id, Lookup.pending) }, uniquingKeysWith: { first, _ in first })
        self.channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.subscribedKeys = Set(subscribedFeeds.map(CatalogMerge.feedKey))
    }

    /// Nach einer Änderung der Abos. Kanäle ohne offene Möglichkeit
    /// fallen aus der Auswahl.
    public mutating func updateSubscribedFeeds(_ feeds: some Sequence<URL>) {
        subscribedKeys = Set(feeds.map(CatalogMerge.feedKey))
        let still = selected.filter { isSelectable($0) }
        selected = still
    }

    // MARK: Suche

    /// Kanäle, für die noch gesucht wird, in der Reihenfolge der Datei.
    public var pendingIDs: [String] {
        channels.map(\.id).filter { lookups[$0] == .pending }
    }

    /// Kanäle, deren Suche erledigt ist, gleich mit welchem Ergebnis.
    public var lookupDoneCount: Int {
        channels.count - pendingIDs.count
    }

    public mutating func recordResults(_ results: [CatalogPodcast], for id: String) {
        guard let channel = channelsByID[id] else { return }
        let ranked = ChannelCounterpartRanking.ranked(results, forChannel: channel.title)
        lookups[id] = ranked.isEmpty ? .nothing : .found(ranked)
        if !hasUserChanges, hasRecommendation(id) { selected.insert(id) }
    }

    public mutating func recordFailure(for id: String) {
        guard channelsByID[id] != nil else { return }
        lookups[id] = .failed
    }

    /// Beendet die Suche. Was noch wartete, gilt als nicht gesucht.
    public mutating func skipRemainingLookups() {
        for id in pendingIDs { lookups[id] = .skipped }
    }

    /// Sucht noch einmal für Kanäle, deren Suche scheiterte oder beendet wurde.
    public mutating func retryUnfinishedLookups() {
        for (id, lookup) in lookups where lookup == .failed || lookup == .skipped {
            lookups[id] = .pending
        }
    }

    // MARK: Möglichkeiten

    /// Alle passenden Podcasts, auch schon abonnierte.
    public func candidates(for id: String) -> [CatalogPodcast] {
        if case .found(let list) = lookups[id] { return list }
        return []
    }

    /// Passende Podcasts, die noch nicht abonniert sind.
    public func openCandidates(for id: String) -> [CatalogPodcast] {
        candidates(for: id).filter { !isSubscribed($0) }
    }

    public func isChannelSubscribed(_ id: String) -> Bool {
        guard let channel = channelsByID[id] else { return false }
        return subscribedKeys.contains(CatalogMerge.feedKey(channel.feedURL))
    }

    /// Ist einer der passenden Podcasts schon abonniert?
    public func isAudioSubscribed(_ id: String) -> Bool {
        candidates(for: id).contains(where: isSubscribed)
    }

    /// Was sich für den Kanal noch abonnieren lässt, die Empfehlung zuerst.
    public func availableTargets(for id: String) -> [Target] {
        guard channelsByID[id] != nil else { return [] }
        var targets = openCandidates(for: id).map { Target.audioPodcast($0.feedURL) }
        if !isChannelSubscribed(id) { targets.append(.youTubeChannel) }
        return targets
    }

    /// Was abonniert wird, wenn der Kanal ausgewählt ist: die eigene Wahl,
    /// sonst die Empfehlung. `nil`, wenn schon alles abonniert ist.
    public func target(for id: String) -> Target? {
        let available = availableTargets(for: id)
        if let choice = choices[id], available.contains(choice) { return choice }
        return available.first
    }

    public func isSelectable(_ id: String) -> Bool {
        !availableTargets(for: id).isEmpty
    }

    /// Gibt es einen Audio-Podcast, der noch nicht abonniert ist?
    public func hasRecommendation(_ id: String) -> Bool {
        !openCandidates(for: id).isEmpty
    }

    public var recommendedIDs: [String] { channels.map(\.id).filter(hasRecommendation) }
    public var selectableIDs: [String] { channels.map(\.id).filter(isSelectable) }

    // MARK: Auswählen

    public mutating func toggle(_ id: String) {
        guard isSelectable(id) else { return }
        hasUserChanges = true
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Legt fest, was für den Kanal abonniert wird, und wählt ihn aus.
    public mutating func choose(_ target: Target, for id: String) {
        guard availableTargets(for: id).contains(target) else { return }
        hasUserChanges = true
        choices[id] = target
        selected.insert(id)
    }

    public mutating func selectRecommended() {
        hasUserChanges = true
        selected = Set(recommendedIDs)
    }

    public mutating func selectAll() {
        hasUserChanges = true
        selected = Set(selectableIDs)
    }

    public mutating func deselectAll() {
        hasUserChanges = true
        selected = []
    }

    // MARK: Abonnieren

    /// Die Abos, die beim Abonnieren entstehen, in der Reihenfolge der
    /// Datei, jeder Feed nur einmal.
    public var subscriptions: [Subscription] {
        var result: [Subscription] = []
        var indexByKey: [String: Int] = [:]
        for channel in channels where selected.contains(channel.id) {
            guard let target = target(for: channel.id) else { continue }
            let subscription: Subscription
            switch target {
            case .audioPodcast(let feed):
                let title = openCandidates(for: channel.id).first { $0.feedURL == feed }?.title
                subscription = Subscription(feedURL: feed, title: title ?? channel.displayTitle,
                                            isAudioPodcast: true, channelIDs: [channel.id])
            case .youTubeChannel:
                subscription = Subscription(feedURL: channel.feedURL, title: channel.displayTitle,
                                            isAudioPodcast: false, channelIDs: [channel.id])
            }
            if let index = indexByKey[subscription.id] {
                result[index].channelIDs.append(channel.id)
            } else {
                indexByKey[subscription.id] = result.count
                result.append(subscription)
            }
        }
        return result
    }

    private func isSubscribed(_ podcast: CatalogPodcast) -> Bool {
        podcast.knownFeedURLs.contains { subscribedKeys.contains(CatalogMerge.feedKey($0)) }
    }
}
