//
//  KnowledgeMarks.swift
//  PodcastAIKit
//
//  Was sich dieses Gerät zu Fakten und Kapitel-Tags merkt, unter den Namen
//  von 0.12: Folgen ohne Ergebnis je Systemversion, Lücken und abgelehnte
//  Abschnitte der Fakten, der Stand angefangener Einordnungen und wie
//  schnell das Gerätemodell Tags wählt. Bis zur Stufe „Wissen“ lagen die
//  Zugriffe im `AppModel`. Die Stufe und der alte Weg hinter dem Schalter
//  lesen und schreiben jetzt dieselben Dateien in `DeviceState`.
//

import Foundation
import PodcastAICore
import PodcastAIIntelligence
import PodcastAIKnowledge
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

    /// Kennung eines Abschnitts für die Lücken: erster und letzter Beleg und
    /// ihre Zahl. Ohne Systemversion, anders als bei den Ablehnungen: eine
    /// Lücke bleibt auch nach einem Update eine Lücke.
    public static func factSliceID(_ slice: [Evidence]) -> String {
        [slice.first?.id.rawValue ?? "", slice.last?.id.rawValue ?? "", String(slice.count)]
            .joined(separator: "|")
    }

    /// Die Zeitspanne jeder Lücke, vom Anfang ihres ersten bis zum Ende
    /// ihres letzten Belegs. Lücken, deren Belege es nicht mehr gibt, etwa
    /// nach einem neuen Transkript, fallen weg.
    public static func factGapSpans(_ gaps: Set<String>, in byID: [EvidenceID: Evidence]) -> [MediaTimeRange] {
        gaps.compactMap { gap in
            let parts = gap.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let first = byID[EvidenceID(rawValue: String(parts[0]))]?.range,
                  let last = byID[EvidenceID(rawValue: String(parts[1]))]?.range else { return nil }
            return MediaTimeRange(start: min(first.start, last.start), end: max(first.end, last.end))
        }
    }

    // MARK: - Abgelehnte Abschnitte

    static let rejectedFactSlicesKey = "com.podcastai.rejectedFactSlices"
    /// So viele Ablehnungen merkt sich die App höchstens. Die ältesten fallen heraus.
    static let rejectedFactSliceLimit = 500

    /// Abschnitte, die das Gerätemodell abgelehnt hat. Nur auf diesem Gerät,
    /// ohne Eintrag in der Datenbank.
    static func rejectedFactSliceList(in state: DeviceState) -> [String] {
        state.value([String].self, for: rejectedFactSlicesKey) {
            UserDefaults.standard.stringArray(forKey: rejectedFactSlicesKey)
        } ?? []
    }

    public static func rejectedFactSlices(in state: DeviceState = .shared) -> Set<String> {
        Set(rejectedFactSliceList(in: state))
    }

    public static func rememberRejectedFactSlice(_ key: String, in state: DeviceState = .shared) {
        var list = rejectedFactSliceList(in: state)
        guard !list.contains(key) else { return }
        list.append(key)
        state.set(Array(list.suffix(rejectedFactSliceLimit)), for: rejectedFactSlicesKey)
    }

    /// Vergisst die Ablehnungen gelöschter Folgen. Ihre Kennung beginnt mit
    /// der Kennung der Folge (``factSliceKey(_:_:)``).
    public static func forgetRejectedFactSlices(of ids: Set<EpisodeID>, in state: DeviceState = .shared) {
        guard !ids.isEmpty else { return }
        let list = rejectedFactSliceList(in: state)
        let kept = list.filter { key in
            guard let episode = key.split(separator: "|", maxSplits: 1).first else { return true }
            return !ids.contains(EpisodeID(rawValue: String(episode)))
        }
        guard kept.count != list.count else { return }
        state.set(kept, for: rejectedFactSlicesKey)
    }

    /// Kennung eines Abschnitts. Belege haben stabile Kennungen, erster und
    /// letzter Beleg und ihre Zahl bestimmen den Abschnitt. Die Version des
    /// Systems gehört dazu: ein neues Modell bekommt eine neue Gelegenheit.
    public static func factSliceKey(_ episodeID: EpisodeID, _ slice: [Evidence]) -> String {
        [
            episodeID.rawValue, slice.first?.id.rawValue ?? "", slice.last?.id.rawValue ?? "",
            String(slice.count), systemVersion,
        ].joined(separator: "|")
    }

    // MARK: - Stand der Einordnung

    public static let taggingProgressKey = "chapterTaggingProgress"

    /// Der Stand aller angefangenen Folgen, als Datei in `DeviceState`. Er
    /// trägt die fertigen Kapitel-Tags und wächst mit jeder angefangenen Folge.
    static func allTaggingProgress(in state: DeviceState) -> [String: ChapterTaggingProgress] {
        state.value([String: ChapterTaggingProgress].self, for: taggingProgressKey) {
            (UserDefaults.standard.dictionary(forKey: taggingProgressKey) as? [String: Data])?
                .compactMapValues { try? JSONDecoder().decode(ChapterTaggingProgress.self, from: $0) }
        } ?? [:]
    }

    public static func taggingProgress(for id: EpisodeID, in state: DeviceState = .shared) -> ChapterTaggingProgress? {
        allTaggingProgress(in: state)[id.rawValue]
    }

    /// Tags, die der gemerkte Stand der Einordnung anderer Folgen nennt. Sie
    /// stehen noch in keinem Kapitel-Tag, gehören aber zu Folgen, die es
    /// noch gibt. Das Aufräumen nach einer Löschung lässt sie stehen, sonst
    /// fiele ihr Kapitel-Tag beim Speichern still weg.
    public static func tagsInTaggingProgress(
        except excluded: Set<EpisodeID>, in state: DeviceState = .shared
    ) -> Set<InterestID> {
        var ids: Set<InterestID> = []
        for (key, progress) in allTaggingProgress(in: state) where !excluded.contains(EpisodeID(rawValue: key)) {
            ids.formUnion(progress.tags.map(\.interestID))
        }
        return ids
    }

    public static func setTaggingProgress(
        _ progress: ChapterTaggingProgress?, for id: EpisodeID, in state: DeviceState = .shared
    ) {
        var stored = allTaggingProgress(in: state)
        if let progress, progress.isStarted {
            guard stored[id.rawValue] != progress else { return }
            stored[id.rawValue] = progress
        } else {
            guard stored[id.rawValue] != nil else { return }
            stored[id.rawValue] = nil
        }
        state.set(stored, for: taggingProgressKey)
    }

    // MARK: - Tempo der Tags

    /// Je Systemversion: Ein neues Modell wird neu gemessen. Sonst bliebe
    /// ein einmal langsames Gerät bei Private Cloud Compute, denn dort
    /// entstehen keine neuen Messungen auf dem Gerät. In den
    /// Benutzereinstellungen, klein.
    public static var taggingPaceKey: String { "chapterTaggingPace-\(systemVersion)" }

    /// Wie schnell das Gerätemodell auf diesem Gerät Tags wählt.
    public static var taggingPace: TaggingPace {
        guard let data = UserDefaults.standard.data(forKey: taggingPaceKey),
              let pace = try? JSONDecoder().decode(TaggingPace.self, from: data) else { return TaggingPace() }
        return pace
    }

    public static func recordTaggingPace(_ selections: [TagSelection]) {
        // Auch ein Aufruf, der auf dem Gerät an der Zeit scheiterte und dann
        // von Private Cloud Compute kam, zählt als langsamer Aufruf.
        let local = selections.compactMap { $0.tier == .onDevice ? $0.seconds : $0.timedOutOnDeviceSeconds }
        guard !local.isEmpty else { return }
        var pace = taggingPace
        for seconds in local { pace.record(onDeviceSeconds: seconds) }
        if let data = try? JSONEncoder().encode(pace) {
            UserDefaults.standard.set(data, forKey: taggingPaceKey)
        }
    }
}
