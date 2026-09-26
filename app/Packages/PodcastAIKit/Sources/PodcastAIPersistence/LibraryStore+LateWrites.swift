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

    /// Entfernt genau die Zeilen, die ein geschütztes Schreiben angelegt hat
    /// (``WriteReceipt``): Belege, Transkripte samt Segmenten, Fakten,
    /// Kapitel-Tags, neu angelegte Medienfassungen und erkannte Tags, auf
    /// die sonst nichts zeigt.
    ///
    /// Für eine Arbeit, deren Folge gelöscht wurde, gleich nachdem der
    /// Wächter das Schreiben durchgelassen hatte. Anders als
    /// ``removeAnalysis(ofEpisode:mediaVersionID:)`` braucht es keine
    /// Audioadresse, trifft also auch YouTube-Folgen, und es nimmt nichts
    /// mit, was schon vorher da war. Die Zeile der Folge bleibt, es entsteht
    /// kein Merkzeichen.
    @discardableResult
    public func removeWrites(_ receipt: WriteReceipt) throws -> RemovalReport {
        var report = RemovalReport()
        guard !receipt.isEmpty else { return report }
        evidenceChanged()
        defer { evidenceChanged() }

        let evidenceKeys = Set(receipt.evidenceIDs.map(\.rawValue))
        if !evidenceKeys.isEmpty {
            let rows = try modelContext.fetch(FetchDescriptor<StoredEvidence>(
                predicate: #Predicate { evidenceKeys.contains($0.identifier) }))
            report.evidenceIDs = Set(rows.map(\.identifier)).sorted().map(EvidenceID.init(rawValue:))
            for row in rows { modelContext.delete(row) }
        }
        let factKeys = Set(receipt.factIDs)
        if !factKeys.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<StoredFact>(
                predicate: #Predicate { factKeys.contains($0.identifier) })) {
                modelContext.delete(row)
            }
        }
        let tagKeys = Set(receipt.chapterTagIDs.map(\.rawValue))
        if !tagKeys.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
                predicate: #Predicate { tagKeys.contains($0.identifier) })) {
                modelContext.delete(row)
            }
        }
        let transcriptKeys = Set(receipt.transcriptIDs.map(\.rawValue))
        if !transcriptKeys.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<StoredTranscript>(
                predicate: #Predicate { transcriptKeys.contains($0.identifier) })) {
                modelContext.delete(row)
            }
        }
        // Erst speichern: Die Abfrage unten sähe gelöschte Transkripte sonst noch.
        try modelContext.save()

        // Eine Fassung, die dieses Schreiben angelegt hat, geht mit, solange
        // kein anderes Transkript an ihr hängt.
        let mediaKeys = Set(receipt.mediaVersionIDs.map(\.rawValue))
        var removedMedia: Set<String> = []
        if !mediaKeys.isEmpty {
            for media in try modelContext.fetch(FetchDescriptor<StoredMediaVersion>(
                predicate: #Predicate { mediaKeys.contains($0.identifier) }))
            where (media.transcripts ?? []).isEmpty {
                removedMedia.insert(media.identifier)
                modelContext.delete(media)
            }
        }
        if !removedMedia.isEmpty {
            let key = receipt.episodeID.rawValue
            for episode in try modelContext.fetch(FetchDescriptor<StoredEpisode>(
                predicate: #Predicate { $0.identifier == key })) {
                if let current = episode.currentMediaVersionIdentifier, removedMedia.contains(current) {
                    episode.currentMediaVersionIdentifier = nil
                }
            }
            report.mediaVersionIDs = removedMedia.sorted().map(MediaVersionID.init(rawValue:))
        }
        try modelContext.save()
        try removeOrphanedDetectedTags(receipt.tagIDs)
        return report
    }
}
#endif
