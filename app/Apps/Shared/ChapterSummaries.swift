//
//  ChapterSummaries.swift
//  PodcastAI
//
//  Die Folge nach Kapiteln: Grenzen, ein Satz je Kapitel und der Weg
//  zurück in die Originalfolge.
//
//  Der Satz je Kapitel entsteht auf Abruf, wenn jemand den Reiter „Kapitel“
//  öffnet, mit Apple Intelligence auf dem Gerät. Fehlt das Gerätemodell,
//  springt Private Cloud Compute ein, sofern es in den Einstellungen an ist.
//  Die Datenbank bleibt, wie sie ist: Die Sätze liegen je Folge als Datei
//  unter Application Support, mit einem Schlüssel aus Fassung, Transkript,
//  Kapitelgrenzen und Sprache der App. Ändert sich eines davon, entsteht
//  der Satz neu. „Folge löschen“ nimmt die Datei mit, „Audio entfernen“
//  lässt sie stehen.
//

import Foundation
import Synchronization
import PodcastAIKit

// MARK: - Zwischenspeicher

enum ChapterSummaryCache {

    /// Ein gespeicherter Satz. Ohne Text: Das Modell hat das Kapitel
    /// abgelehnt oder keinen brauchbaren Satz geliefert. Dann versucht es
    /// die App erst nach einer Änderung am Kapitel noch einmal.
    struct Entry: Codable, Sendable, Hashable {
        let text: String?
        /// Kennung der Stufe, wie bei den Fakten.
        let modelTier: String
    }

    /// Steigt, wenn sich Regeln oder Anweisungen ändern. Dann entstehen die
    /// Sätze neu.
    static let version = 1

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PodcastAI/ChapterSummaries", isDirectory: true)
    }

    static func file(for id: EpisodeID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).json")
    }

    /// Was einen Satz bestimmt: Fassung und Stand des Transkripts, Anfang
    /// und Ende des Kapitels und die Sprache, in der er formuliert ist.
    static func key(for section: ChapterSection, evidence: [Evidence], language: AppLanguage) -> String? {
        guard let first = evidence.first else { return nil }
        return [
            "v\(version)", first.mediaVersionID.rawValue, "r\(first.transcriptRevision.value)",
            "\(section.range.start.milliseconds)", "\(section.range.end.milliseconds)", language.rawValue,
        ].joined(separator: "|")
    }

    private struct State {
        var removals = 0
        var removed: [EpisodeID: Int] = [:]
    }

    private static let state = Mutex(State())

    /// Der Stand der Löschungen, gezogen vor dem Formulieren. Geschrieben
    /// wird nur, wenn die Folge seitdem nicht gelöscht wurde.
    static var ticket: Int { state.withLock { $0.removals } }

    /// Alle Sätze einer Folge, aus der Datei, außerhalb des Hauptthreads.
    static func load(_ id: EpisodeID) async -> [String: Entry] {
        await Task.detached(priority: .userInitiated) { () -> [String: Entry] in
            guard let data = try? Data(contentsOf: file(for: id)) else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }.value
    }

    /// Schreibt die Sätze einer Folge. Was nicht mehr zu einem Kapitel
    /// passt, fällt dabei heraus.
    static func save(_ entries: [String: Entry], for id: EpisodeID, ticket: Int) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            // Prüfen und Schreiben unter derselben Sperre wie das Löschen,
            // sonst legte ein später Lauf die Datei einer gelöschten Folge neu an.
            state.withLock { state in
                if let at = state.removed[id], at > ticket { return }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file(for: id), options: .atomic)
            }
        }.value
    }

    /// Entfernt die Sätze dieser Folgen.
    static func remove(episodes: [EpisodeID]) {
        guard !episodes.isEmpty else { return }
        state.withLock { state in
            state.removals += 1
            for id in episodes {
                state.removed[id] = state.removals
                try? FileManager.default.removeItem(at: file(for: id))
            }
        }
    }
}

// MARK: - Kapitel einer Folge

extension AppModel {

    /// Die Kapitel aus dem Feed, soweit sie schon da sind.
    func feedChapters(for episode: Episode) -> [Chapter] {
        episode.publisherChapters.isEmpty ? (chapterCache[episode.id] ?? []) : episode.publisherChapters
    }

    /// Die Kapitel mit Grenzen. Ohne Kapitel aus dem Feed schneidet der
    /// Code eigene Abschnitte aus den Belegen, außerhalb des Hauptthreads,
    /// denn dafür rechnet er Satzvektoren.
    nonisolated static func chapterSections(
        chapters: [Chapter], duration: MediaDuration?, evidence: [Evidence]
    ) async -> [ChapterSection] {
        await Task.detached(priority: .userInitiated) {
            ChapterSections.sections(chapters: chapters, duration: duration, evidence: evidence)
        }.value
    }

    /// Die gespeicherten Sätze je Kapitel, nach dem Anfang des Kapitels.
    func storedChapterSummaries(
        for episode: Episode, sections: [ChapterSection], evidence: [Evidence]
    ) async -> [Int64: ChapterSummaryCache.Entry] {
        let stored = await ChapterSummaryCache.load(episode.id)
        let groups = ChapterSections.group(evidence, into: sections) { $0.range?.start }
        var result: [Int64: ChapterSummaryCache.Entry] = [:]
        for section in sections {
            guard let key = ChapterSummaryCache.key(
                for: section, evidence: groups[section.index], language: AppLanguage.current),
                  let entry = stored[key] else { continue }
            result[section.id] = entry
        }
        return result
    }

    /// Formuliert die fehlenden Sätze, ein Kapitel nach dem anderen, und
    /// meldet jeden, sobald er da ist. Nur auf Abruf, nie für Ton. Endet
    /// ohne Meldung, wenn kein Modell bereitsteht; dann bleibt es bei
    /// Kapiteltitel, Fakten und Transkript.
    func prepareChapterSummaries(
        for episode: Episode, sections: [ChapterSection], evidence: [Evidence],
        onSummary: (Int64, ChapterSummaryCache.Entry) -> Void
    ) async {
        // Kein eigener Riegel: Ändern sich die Kapitel, bricht SwiftUI den
        // vorigen Lauf ab, und der neue beginnt mit dem, was schon gespeichert ist.
        guard !sections.isEmpty else { return }
        let ticket = ChapterSummaryCache.ticket
        let removals = removalCount
        let language = AppLanguage.current
        let groups = ChapterSections.group(evidence, into: sections) { $0.range?.start }
        let stored = await ChapterSummaryCache.load(episode.id)
        var entries: [String: ChapterSummaryCache.Entry] = [:]
        var open: [(section: ChapterSection, key: String)] = []
        for section in sections {
            guard let key = ChapterSummaryCache.key(
                for: section, evidence: groups[section.index], language: language) else { continue }
            if let entry = stored[key] { entries[key] = entry } else { open.append((section, key)) }
        }
        guard !open.isEmpty else { return }

        await refreshModelStatus()
        guard case .success = modelStatus.resolve(.summarize) else { return }
        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(excerptLimit: 400, maximumCandidates: Self.summaryPassageLimit)))
        var changed = false
        for (section, key) in open {
            if Task.isCancelled { break }
            let passages = ChapterSections.balanced(
                groups[section.index], across: [section], quota: Self.summaryPassageLimit,
                limit: Self.summaryPassageLimit) { $0.range?.start ?? .zero }
            do {
                // Den Titel eines abgeleiteten Abschnitts hat die App gesetzt,
                // er sagt nichts über den Inhalt.
                let summary = try await extractor.summarizeChapter(
                    passages, title: section.isDerived ? nil : section.title, availability: modelStatus)
                let entry = ChapterSummaryCache.Entry(
                    text: summary?.text, modelTier: summary?.modelTier.rawValue ?? "")
                entries[key] = entry
                changed = true
                if !wasRemoved(episode.id, since: removals) { onSummary(section.id, entry) }
            } catch let error as ExtractorError {
                switch error {
                case .generationRejected:
                    // Dieselbe Eingabe scheitert jedes Mal gleich.
                    entries[key] = ChapterSummaryCache.Entry(text: nil, modelTier: "")
                    changed = true
                case .generationFailed:
                    // Last oder Zeit: beim nächsten Öffnen noch einmal.
                    continue
                case .modelUnavailable:
                    await refreshModelStatus()
                    if changed { await ChapterSummaryCache.save(entries, for: episode.id, ticket: ticket) }
                    return
                }
            } catch {
                break
            }
        }
        if changed { await ChapterSummaryCache.save(entries, for: episode.id, ticket: ticket) }
    }

    /// So viele Stellen eines Kapitels sieht das Modell für seinen Satz.
    static let summaryPassageLimit = 12

    // MARK: - Original öffnen

    /// Öffnet die Originalfolge an einer Stelle, auf Tippen. Die Zeit legt
    /// der Code fest, aus der Ausgabe, dem Beleg oder dem Plan.
    func openOriginal(episodeID: EpisodeID, at position: MediaTime) async {
        var episode = loadedEpisode(episodeID)
        if episode == nil { episode = (try? await store.episodes(ids: [episodeID]))?.first }
        guard let episode else {
            lastError = String(localized: "Die Originalfolge ist nicht mehr in der Bibliothek.")
            return
        }
        playEpisode(episode, at: max(0, position.seconds))
    }
}
