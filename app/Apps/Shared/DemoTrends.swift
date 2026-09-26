//
//  DemoTrends.swift
//  PodcastAI
//
//  Feste Daten für „Angesagt“ und „Neu“ in UI-Tests, seit 0.12. Nur mit
//  dem Startargument `-demo-trends`, zusammen mit `-demo-content`, und nur
//  in einen leeren Speicher (`DemoContent.seed` ruft es auf).
//
//  Die Beispielfolge allein trägt kein Tag in drei Quellen. Hier kommen
//  Kapitel-Tags aus drei weiteren, erfundenen Quellen dazu: „KI-Verordnung“
//  in dieser Woche zweimal je Quelle, und ein älteres Kapitel, damit die
//  Bibliothek Vorgeschichte hat. Folgen dazu gibt es nicht; die Tag-Seite
//  zeigt solche Kapitel als „Unbekannte Folge“. Dazu ein Besuch der Seite
//  „Datenschutz“ vor zwei Tagen, damit sie die Aussage der Beispielfolge
//  als neu zählt.
//

import Foundation
import PodcastAIKit

enum DemoTrends {

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-demo-trends") }

    static func seed(into store: LibraryStore) async {
        let day: TimeInterval = 86_400
        let now = Date()
        do {
            guard let trending = try await store.resolveTag("KI-Verordnung"),
                  let older = try await store.resolveTag("Haftung") else { return }
            for (index, name) in ["a", "b", "c"].enumerated() {
                let episodeID = EpisodeID(stable: "demo-trend-\(name)")
                let media = MediaVersionID(stable: "demo-trend-\(name)")
                let published = now.addingTimeInterval(-Double(index + 2) * day)
                let tags = [0, 300_000].map { start in
                    ChapterTag(
                        episodeID: episodeID, mediaVersionID: media, chapterStartMs: start,
                        chapterEndMs: start + 300_000, interestID: trending.id, normalizedKey: "",
                        confidence: 0.9, matchedKnown: true, sourceID: SourceID(stable: "demo-trend-quelle-\(name)"),
                        publishedAt: published, transcriptRevision: .initial)
                }
                try await store.save(chapterTags: tags, forEpisode: episodeID, transcriptRevision: .initial)
            }
            let history = EpisodeID(stable: "demo-trend-alt")
            try await store.save(chapterTags: [ChapterTag(
                episodeID: history, mediaVersionID: MediaVersionID(stable: "demo-trend-alt"), chapterStartMs: 0,
                chapterEndMs: 300_000, interestID: older.id, normalizedKey: "", confidence: 0.9, matchedKnown: true,
                sourceID: SourceID(stable: "demo-trend-quelle-a"), publishedAt: now.addingTimeInterval(-20 * day),
                transcriptRevision: .initial)], forEpisode: history, transcriptRevision: .initial)

            if let privacy = try await store.resolveTag("Datenschutz") {
                DeviceState.shared.set([privacy.id.rawValue: now.addingTimeInterval(-2 * day)],
                                       for: AppModel.tagPageVisitsKey)
            }
        } catch {
            NSLog("Demo-Trends konnten nicht angelegt werden: %@", error.localizedDescription)
        }
    }
}
