//
//  KnowledgeMarks.swift
//  PodcastAIKit
//
//  Was sich dieses Gerät zu Fakten und Kapitel-Tags merkt, unter den Namen
//  von 0.12: Folgen ohne Ergebnis je Systemversion und die Lücken der
//  Fakten. Bis zur Stufe „Wissen“ lagen die Zugriffe im `AppModel`. Die
//  Stufe und der alte Weg hinter dem Schalter lesen und schreiben jetzt
//  dieselben Dateien in `DeviceState`.
//

import Foundation
import PodcastAICore
import PodcastAIPersistence

public enum KnowledgeMarks {

    /// Die Systemversion als „27.0“. Ein neues Modell bekommt eine neue Gelegenheit.
    static var systemVersion: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "\(system.majorVersion).\(system.minorVersion)"
    }

    /// Folgen, bei denen ein Lauf ohne Fakten endete: alles abgelehnt oder
    /// keine überprüfbare Aussage. Das Einreihen lässt sie aus, „Jetzt
    /// ermitteln“ nicht. Je Systemversion, nur auf diesem Gerät.
    public static var factsSettledKey: String { "factsSettled-\(systemVersion)" }

    /// Folgen, die ohne ein einziges Tag eingeordnet sind. Je Systemversion,
    /// wie bei den Fakten.
    public static var tagsSettledKey: String { "tagsSettled-\(systemVersion)" }

    public static func factsSettled(in state: DeviceState = .shared) -> StoredIDs<EpisodeSubject> {
        StoredIDs(key: factsSettledKey, state: state)
    }

    public static func tagsSettled(in state: DeviceState = .shared) -> StoredIDs<EpisodeSubject> {
        StoredIDs(key: tagsSettledKey, state: state)
    }

    // MARK: - Lücken

    /// Abschnitte, die beim letzten Lauf einer Folge aus einem Grund
    /// gescheitert sind, der vorbeigeht: Last, Zeitüberschreitung. Je Folge
    /// die Kennungen der Abschnitte. Nur auf diesem Gerät.
    public static let factGapsKey = "com.podcastai.factGaps"

    static func allFactGaps(in state: DeviceState) -> [String: [String]] {
        state.value([String: [String]].self, for: factGapsKey) {
            UserDefaults.standard.dictionary(forKey: factGapsKey) as? [String: [String]]
        } ?? [:]
    }

    public static func factGaps(of id: EpisodeID, in state: DeviceState = .shared) -> Set<String> {
        Set(allFactGaps(in: state)[id.rawValue] ?? [])
    }

    /// Folgen, denen nach dem letzten Lauf Abschnitte fehlen.
    public static func episodesWithFactGaps(in state: DeviceState = .shared) -> Set<EpisodeID> {
        Set(allFactGaps(in: state).keys.map(EpisodeID.init(rawValue:)))
    }

    /// Merkt sich die Lücken einer Folge. Ohne Lücken fällt der Eintrag weg.
    public static func setFactGaps(_ gaps: Set<String>, for id: EpisodeID, in state: DeviceState = .shared) {
        var all = allFactGaps(in: state)
        let previous = all[id.rawValue]
        all[id.rawValue] = gaps.isEmpty ? nil : gaps.sorted()
        guard all[id.rawValue] != previous else { return }
        state.set(all, for: factGapsKey)
    }
}
