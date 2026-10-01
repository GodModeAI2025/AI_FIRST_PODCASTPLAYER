//
//  PlayerValues.swift
//  PodcastAIPlayerKit
//
//  Wertetypen des Players: die Folge samt Podcast, Tempo, Schlaf-Timer und
//  Warteschlange. Alles ohne Oberfläche und ohne Datenbank, damit es sich
//  auf dem Mac testen lässt.
//

import Foundation
import PodcastAICore

/// Eine Folge, so wie ein Player sie zeigt und abspielt.
public struct PlayerItem: Hashable, Sendable, Identifiable {
    public let episode: Episode
    public let showTitle: String
    public let showArtworkURL: URL?
    /// Wo die Wiedergabe weitergehen soll. `nil`: von vorn.
    public var resume: MediaTime?

    public init(episode: Episode, showTitle: String, showArtworkURL: URL?, resume: MediaTime? = nil) {
        self.episode = episode
        self.showTitle = showTitle
        self.showArtworkURL = showArtworkURL
        self.resume = resume
    }

    public var id: EpisodeID { episode.id }
    public var title: String { episode.title }

    /// Das Cover der Folge, sonst das des Podcasts.
    public var artworkURL: URL? { episode.artworkURL ?? showArtworkURL }

    /// Die Adresse zum Streamen. Nur `http` und `https`; `http` wandert wie
    /// überall in der App auf `https`.
    public var streamURL: URL? {
        guard let url = episode.audioURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return SafeHTTP.secureVariant(of: url)
    }

    public var isPlayable: Bool { streamURL != nil }

    /// Länge laut Feed in Sekunden, 0 wenn unbekannt.
    public var declaredSeconds: Double {
        Double(episode.declaredDuration?.milliseconds ?? 0) / 1000
    }

    /// Die Stelle, an der ein Start fortsetzt. Liegt sie kurz vor dem Ende,
    /// gilt die Folge als gehört und beginnt von vorn.
    public var startPosition: MediaTime {
        guard let resume, resume.milliseconds > 0 else { return .zero }
        let total = episode.declaredDuration?.milliseconds ?? 0
        if total > 0, resume.milliseconds >= total - 15_000 { return .zero }
        return resume
    }
}

/// Wiedergabetempo. Dieselben Stufen wie in der iOS-App.
public enum PlaybackSpeed {
    public static let options: [Float] = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0]

    /// Die nächste Stufe, nach der letzten wieder die erste.
    public static func next(after rate: Float) -> Float {
        guard let index = options.firstIndex(where: { abs($0 - rate) < 0.01 }) else { return 1.0 }
        return options[(index + 1) % options.count]
    }

    public static func label(_ rate: Float) -> String {
        let text = rate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text)×"
    }
}

/// Wann der Schlaf-Timer die Wiedergabe anhält.
public enum SleepTimerSetting: Hashable, Sendable {
    case minutes(Int)
    case endOfEpisode

    public static let choices: [SleepTimerSetting] = [
        .minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfEpisode,
    ]

    public var title: String {
        switch self {
        case .minutes(let count):
            String(localized: "\(count) Minuten", bundle: .module, comment: "Schlaf-Timer")
        case .endOfEpisode:
            String(localized: "Am Ende der Folge", bundle: .module, comment: "Schlaf-Timer")
        }
    }
}

/// Der Stand eines laufenden Schlaf-Timers. Er zählt gespielte Zeit, keine
/// Uhrzeit: pausiert die Wiedergabe, steht auch er.
public struct SleepTimerState: Equatable, Sendable {
    public private(set) var setting: SleepTimerSetting
    public private(set) var remaining: TimeInterval?

    public init(_ setting: SleepTimerSetting) {
        self.setting = setting
        switch setting {
        case .minutes(let count): remaining = TimeInterval(max(1, count) * 60)
        case .endOfEpisode: remaining = nil
        }
    }

    /// `true`, wenn die Zeit abgelaufen ist.
    public mutating func tick(playedSeconds: TimeInterval) -> Bool {
        guard let left = remaining else { return false }
        let next = left - max(0, playedSeconds)
        remaining = max(0, next)
        return next <= 0
    }

    public var stopsAtEndOfEpisode: Bool { setting == .endOfEpisode }
}

/// Die Warteschlange „Als Nächstes“ dieses Geräts.
///
/// Nur Folgen, die jemand selbst eingereiht hat. Sie liegt in den
/// Benutzereinstellungen des Geräts und nicht im Schema: ohne Schemaänderung
/// gibt es keine Warteschlange über Geräte hinweg.
public struct UpNextQueue: Equatable, Sendable {
    public private(set) var items: [PlayerItem] = []

    public init(items: [PlayerItem] = []) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }

    public mutating func append(_ item: PlayerItem) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    /// Ganz nach vorn, etwa für „Als Nächstes spielen“.
    public mutating func prepend(_ item: PlayerItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
    }

    public mutating func remove(_ id: EpisodeID) {
        items.removeAll { $0.id == id }
    }

    public mutating func removeAll() { items.removeAll() }

    public mutating func popFirst() -> PlayerItem? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func move(from source: IndexSet, to destination: Int) {
        var moved: [PlayerItem] = []
        for index in source.sorted() where items.indices.contains(index) { moved.append(items[index]) }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where items.indices.contains(index) { items.remove(at: index) }
        let target = max(0, min(items.count, destination - before))
        items.insert(contentsOf: moved, at: target)
    }

    // MARK: Ablage

    /// Nur die Kennungen werden gemerkt. Beim Laden kommen die Folgen aus der
    /// Bibliothek; was es dort nicht mehr gibt, fällt weg.
    public var storedIdentifiers: [String] { items.map(\.id.rawValue) }

    public static let defaultsKey = "playerUpNextEpisodeIDs"

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(storedIdentifiers, forKey: Self.defaultsKey)
    }

    public static func storedIdentifiers(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }
}
