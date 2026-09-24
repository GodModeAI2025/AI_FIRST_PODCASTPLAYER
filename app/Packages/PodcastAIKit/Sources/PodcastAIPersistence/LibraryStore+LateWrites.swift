//
//  LibraryStore+LateWrites.swift
//  PodcastAIPersistence
//
//  Aufräumen nach einer Erschließung, die nach dem Löschen ihrer Folge
//  noch geschrieben hat.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore

extension LibraryStore {

    /// Entfernt, was eine Erschließung für eine Fassung einer Folge
    /// geschrieben hat: die Belege der Folge zu dieser Fassung, die
    /// Transkripte der Fassung und die Fassung selbst.
    ///
    /// Anders als ``removeEpisode(_:)`` bleiben die Zeilen der Folge stehen,
    /// und es entsteht kein Merkzeichen. Eine gelöschte Folge trägt ihres
    /// schon. War es eine abbestellte Quelle, die inzwischen neu abonniert
    /// ist, gehört die Zeile der Folge zum neuen Abo. Als Merkzeichen legte
    /// der Feed sie nie wieder an. Hörzustand, Fakten und gemerkte Stellen
    /// schreibt die Erschließung nicht, sie bleiben ebenfalls.
    public func removeAnalysis(
        ofEpisode episodeID: EpisodeID, mediaVersionID: MediaVersionID
    ) throws -> RemovalReport {
        evidenceChanged()
        defer { evidenceChanged() }
        var report = RemovalReport()
        let key = episodeID.rawValue
        let mediaKey = mediaVersionID.rawValue

        let evidence = try modelContext.fetch(FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.episodeIdentifier == key && $0.mediaVersionIdentifier == mediaKey }))
        report.evidenceIDs = Set(evidence.map(\.identifier)).sorted().map(EvidenceID.init(rawValue:))
        for row in evidence { modelContext.delete(row) }

        // Kapitel-Tags schreibt die Einordnung nach den Fakten, zur selben Fassung.
        for tag in try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.episodeIdentifier == key && $0.mediaVersionIdentifier == mediaKey })) {
            modelContext.delete(tag)
        }

        for transcript in try modelContext.fetch(FetchDescriptor<StoredTranscript>(
            predicate: #Predicate { $0.mediaVersion?.identifier == mediaKey })) {
            modelContext.delete(transcript)
        }
        for media in try modelContext.fetch(FetchDescriptor<StoredMediaVersion>(
            predicate: #Predicate { $0.identifier == mediaKey })) {
            modelContext.delete(media)
        }
        // Die Datei kann auch ohne Zeile liegen: geladen wird vor dem Speichern.
        report.mediaVersionIDs = [mediaVersionID]

        // Keine Kopie der Folge zeigt danach noch auf die gelöschte Fassung.
        for episode in try modelContext.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.identifier == key }))
        where episode.currentMediaVersionIdentifier == mediaKey {
            episode.currentMediaVersionIdentifier = nil
        }
        try modelContext.save()
        return report
    }
}
#endif
