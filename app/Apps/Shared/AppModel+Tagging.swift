//
//  AppModel+Tagging.swift
//  PodcastAI
//
//  Tags je Kapitel. Die Einordnung läuft in derselben Arbeit wie die
//  Fakten: gleich nach den Fakten einer Folge und danach für die übrige
//  Bibliothek, neueste Folge zuerst, wenn keine Folge auf Fakten wartet.
//
//  Kandidaten und Ranking rechnet der Code (`ChapterTagCandidates`), das
//  Modell wählt nur Kennungen aus der Liste (`TagSelector`). Ein neuer
//  Oberbegriff kommt aus den Kandidaten und wird ein erkanntes, neutrales
//  Tag. Die Wolke zeigt es erst ab zwei Quellen.
//
//  Fortsetzen: Welche Kapitel fertig sind, merkt sich das Gerät je Folge
//  (`ChapterTaggingProgress` in `DeviceState`). Die Kapitel-Tags gehen erst
//  in die Datenbank, wenn die ganze Folge eingeordnet ist, in einem Schritt.
//  So schreibt der Abgleich nicht nach jedem Kapitel alle Zeilen der Folge neu.
//
//  Die Einordnung einer Folge steht in `KnowledgeJobs` (Paket),
//  Warteschlange und Rückstand führt die Stufe „Wissen“ (`KnowledgeStage`).
//  Hier bleiben der Anstoß für die Hintergrundaufgabe und die Schlüssel
//  der Vermerke.
//

import Foundation
import PodcastAIKit

extension AppModel {

    /// Für die leichte Hintergrundaufgabe `com.podcastai.tagging`: nur Tags,
    /// keine Fakten. Endet die Zeit, bleibt der Stand der Folge gemerkt.
    ///
    /// Die Zeit vom System hält die Hintergrundaufgabe selbst am Tor
    /// (`holdCarrier(.taggingTask)` in `BackgroundWork`).
    public func processPendingTags() async {
        await refreshModelStatus()
        guard let knowledgeStage else { return }
        await knowledgeStage.reconcileTags()
        await knowledgeStage.untilIdle()
    }

    // MARK: - Gemerkt auf diesem Gerät (`KnowledgeMarks` im Paket)

    static var tagsSettledKey: String { KnowledgeMarks.tagsSettledKey }
    static var taggingProgressKey: String { KnowledgeMarks.taggingProgressKey }

    static func taggingProgress(for id: EpisodeID) -> ChapterTaggingProgress? {
        KnowledgeMarks.taggingProgress(for: id)
    }

    /// Tags, die der gemerkte Stand der Einordnung anderer Folgen nennt.
    static func tagsInTaggingProgress(except excluded: Set<EpisodeID>) -> Set<InterestID> {
        KnowledgeMarks.tagsInTaggingProgress(except: excluded)
    }

    static func setTaggingProgress(_ progress: ChapterTaggingProgress?, for id: EpisodeID) {
        KnowledgeMarks.setTaggingProgress(progress, for: id)
    }
}
