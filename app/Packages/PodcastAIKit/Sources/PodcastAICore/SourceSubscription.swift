//
//  SourceSubscription.swift
//  PodcastAICore
//
//  Abonniert oder nicht. Wer nur eine einzelne Folge holt, bekommt den
//  Podcast dazu in die Bibliothek, gekennzeichnet als „nicht abonniert“.
//  Er wird nicht von selbst aktualisiert und nicht als Abo exportiert.
//  Seine Folgen laufen durch dieselbe Erschließung wie alle anderen.
//

import Foundation

extension Source {

    /// Holt die App neue Folgen dieser Quelle von selbst? Nur bei Abos
    /// mit Feed.
    public var refreshesAutomatically: Bool { isSubscribed && feedURL != nil }

    /// Gehört die Quelle in eine Abo-Liste (OPML)? Nur Abos mit einem Feed
    /// im Netz, den eine andere App lesen kann.
    public var isExportableSubscription: Bool {
        guard isSubscribed, kind == .podcastRSS || kind == .youTubeChannel,
              let scheme = feedURL?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Hat jemand jede Folge dieser Quelle einzeln gewählt? Dann nimmt das
    /// Vorbereiten alle, nicht nur die neuesten.
    public var holdsChosenEpisodes: Bool { !isSubscribed || kind == .singleEpisodeLink }

    /// Die Quelle, unter die eine einzeln geholte Folge kommt. Ist der
    /// Podcast schon abonniert, bleibt er es; eine einzelne Folge nimmt
    /// kein Abo zurück.
    public func forSingleEpisode(existing: Source?) -> Source {
        var copy = self
        copy.isSubscribed = existing?.isSubscribed ?? false
        if let existing { copy.addedAt = existing.addedAt }
        return copy
    }
}

/// Welche Folgen einer Quelle die App von selbst vorbereitet.
public enum PreparationCandidates {

    /// Bei Abos die neuesten `perSource` Folgen mit Ton, bei einzeln
    /// geholten Folgen alle mit Ton. Einzelne Folgen hat jemand bewusst
    /// gewählt; sie stehen in der Warteschlange vor dem Archiv, wie neue
    /// Folgen eines Abos.
    public static func newest(in episodes: [Episode], of source: Source?, perSource: Int) -> [Episode] {
        let playable = episodes.filter { $0.audioURL != nil && $0.canBeAnalyzed }
        if source?.holdsChosenEpisodes == true { return playable }
        return Array(playable.prefix(perSource))
    }
}
