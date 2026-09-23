//
//  AudioRetention.swift
//  PodcastAICore
//
//  Welche Audiodatei auf dem Gerät bleibt und warum.
//
//  Die neueste Folge je Podcast bleibt für unterwegs, die bisherige, bis der
//  Ton der neuen auf dem Gerät liegt. Alle anderen spielen nach dem
//  Transkript aus dem Netz. Was jemand mit „Laden (offline)“ geholt hat,
//  bleibt immer, bis „Audio entfernen“. Die Regel steht hier, ohne
//  Dateisystem und ohne Oberfläche, damit sie sich prüfen lässt. Das
//  Aufräumen und die Zeile unter „Audio liegt auf diesem Gerät“ lesen
//  dasselbe Urteil und können sich deshalb nicht widersprechen.
//

import Foundation

public enum AudioRetention {

    /// Die Schalter aus den Einstellungen.
    public struct Rules: Equatable, Sendable {
        /// „Audio entfernen, wenn das Transkript fertig ist“.
        public var removeAfterTranscript: Bool
        /// „Gehörte Folgen nach einem Tag vom Gerät entfernen“.
        public var removeHeard: Bool
        /// „Neueste Folge je Podcast behalten“.
        public var keepNewest: Bool

        public init(removeAfterTranscript: Bool, removeHeard: Bool, keepNewest: Bool) {
            self.removeAfterTranscript = removeAfterTranscript
            self.removeHeard = removeHeard
            self.keepNewest = keepNewest
        }
    }

    /// Was über eine Folge bekannt ist, deren Audio auf dem Gerät liegt.
    public struct Facts: Equatable, Sendable {
        /// Mit „Laden (offline)“ oder „Auf dem Gerät behalten“ geholt.
        public var keptByUser: Bool
        /// Die neueste Folge ihres Podcasts.
        public var isNewest: Bool
        /// Das Transkript ist fertig.
        public var hasTranscript: Bool
        /// Zu Ende gehört, und das liegt länger als einen Tag zurück.
        public var heardLongAgo: Bool
        /// Die App hat die Datei nur geladen, weil es die neueste Folge war.
        public var prefetched: Bool

        public init(keptByUser: Bool = false, isNewest: Bool = false, hasTranscript: Bool = false,
                    heardLongAgo: Bool = false, prefetched: Bool = false) {
            self.keptByUser = keptByUser
            self.isNewest = isNewest
            self.hasTranscript = hasTranscript
            self.heardLongAgo = heardLongAgo
            self.prefetched = prefetched
        }
    }

    /// Was mit der Datei geschieht.
    public enum Verdict: Equatable, Sendable {
        /// Von Hand geladen. Bleibt, bis jemand „Audio entfernen“ wählt.
        case keptByUser
        /// Neueste Folge ihres Podcasts. Bleibt, bis eine neuere kommt oder
        /// sie gehört ist.
        case newest
        /// Gehört nicht mehr aufs Gerät. Das Aufräumen nimmt sie weg, sobald
        /// sie nicht mehr im Player liegt, lädt oder ausgewertet wird.
        case remove
        /// Geht, sobald das Transkript fertig ist.
        case removeAfterTranscript
        /// Geht einen Tag, nachdem die Folge zu Ende gehört ist.
        case removeAfterHeard
        /// Keine Regel nimmt sie weg.
        case stays

        /// Nimmt die App die Datei irgendwann von selbst weg?
        public var isTemporary: Bool {
            switch self {
            case .newest, .remove, .removeAfterTranscript, .removeAfterHeard: true
            case .keptByUser, .stays: false
            }
        }
    }

    /// Das Urteil über eine Datei auf dem Gerät.
    ///
    /// Die Reihenfolge ist die Rangfolge: was jemand selbst geladen hat, vor
    /// der neuesten Folge, vor den Regeln zum Aufräumen. Eine gehörte
    /// neueste Folge fällt nach einem Tag unter „Gehörte Folgen entfernen“
    /// wie jede andere.
    public static func verdict(for facts: Facts, rules: Rules) -> Verdict {
        if facts.keptByUser { return .keptByUser }
        let heardAway = rules.removeHeard && facts.heardLongAgo
        if rules.keepNewest, facts.isNewest, !heardAway { return .newest }
        if heardAway { return .remove }
        if rules.removeAfterTranscript, facts.hasTranscript { return .remove }
        // Nur als neueste Folge geladen, und das ist sie nicht mehr oder die
        // Regel ist aus. Ohne diesen Fall bliebe die Datei für immer liegen.
        if facts.prefetched { return .remove }
        if rules.removeAfterTranscript { return .removeAfterTranscript }
        if rules.removeHeard { return .removeAfterHeard }
        return .stays
    }

    /// Die neueste Folge einer Quelle mit Audiodatei. Die Liste kommt wie aus
    /// dem Speicher, neueste zuerst. Dieselbe Reihenfolge nimmt das
    /// Vorbereiten für „die N neuesten“.
    public static func newest(in episodes: [Episode]) -> Episode? {
        episodes.first { $0.audioURL != nil }
    }

    /// Welche Folgen einer Quelle als neueste ihren Ton behalten: die
    /// neueste und, solange ihr Ton noch kommen soll, dazu die jüngste, deren
    /// Ton schon auf dem Gerät liegt. Zeigt der Feed unterwegs eine neue
    /// Folge, die noch aufs WLAN wartet, bleibt die bisherige so lange da.
    /// Sonst hätte der Podcast gerade dann gar keinen Ton ohne Netz.
    ///
    /// - Parameters:
    ///   - hasFile: Liegt der Ton dieser Folge auf dem Gerät?
    ///   - isComing: Holt die App den Ton der neuesten Folge noch von selbst?
    ///     Gefragt nur, wenn er fehlt.
    public static func keptAsNewest(
        in episodes: [Episode], hasFile: (Episode) -> Bool, isComing: (Episode) -> Bool
    ) -> [EpisodeID] {
        guard let newest = newest(in: episodes) else { return [] }
        guard !hasFile(newest), isComing(newest),
              let previous = episodes.first(where: { $0.id != newest.id && $0.audioURL != nil && hasFile($0) })
        else { return [newest.id] }
        return [newest.id, previous.id]
    }
}
