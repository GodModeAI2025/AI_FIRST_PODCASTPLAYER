//
//  LibraryStore+Editions.swift
//  PodcastAIPersistence
//
//  Ausgaben der Themen-Updates, je Zeile geschrieben (docs/plan-pipeline.md,
//  Schritt 4).
//
//  Bis 0.13 schrieb die App die ganze Liste eines Updates auf einmal
//  (`save(editions:forFeed:)`) und löschte dabei jede Zeile, die in ihrer
//  Liste im Speicher fehlte. Zwei solche Schreibvorgänge mit verschiedenen
//  Listen, etwa eine neue Ausgabe und das Aufräumen nach „Folge löschen“,
//  konnten sich gegenseitig eine Ausgabe wegnehmen, ebenso eine, die ein
//  anderes Gerät gerade angelegt hatte. Jetzt schreibt jede Änderung nur
//  ihre eigene Zeile.
//
//  Eine neue Ausgabe entsteht über Minuten aus den Kapiteln der Bibliothek.
//  In dieser Zeit kann eine ihrer Folgen gelöscht oder eine Quelle
//  abbestellt werden. Deshalb prüft `commit(edition:…)` im selben Schritt
//  wie das Schreiben jede Folge ihrer Stellen mit demselben Wächter wie
//  Transkripte und Fakten (`CommitGuard`). Stellen aus einer Folge, die er
//  ablehnt, fallen heraus, die übrigen rücken zusammen. Bleibt keine, wird
//  nichts geschrieben (Regel 5). Das Datenbankschema ändert sich nicht.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore
import PodcastAISmartFeeds

/// Was das Schreiben einer neuen Ausgabe ergab.
public enum EditionCommit: Sendable, Equatable {
    /// Geschrieben, wie sie jetzt in der Datenbank steht. `dropped` nennt
    /// die Folgen, deren Stellen herausfielen, weil der Wächter sie ablehnte.
    case written(PersonalEpisode, dropped: Set<EpisodeID>)
    /// Das Update gibt es nicht mehr. Nichts geschrieben.
    case feedMissing
    /// Keine Stelle blieb übrig. Nichts geschrieben.
    case nothingLeft(dropped: Set<EpisodeID>)

    /// Die Ausgabe, wie sie geschrieben wurde.
    public var edition: PersonalEpisode? {
        if case .written(let edition, _) = self { edition } else { nil }
    }
}

extension LibraryStore {

    /// Die Ausgaben eines Updates, neueste zuerst. Liest nur die Zeilen
    /// dieses Updates, nicht die ganze Tabelle.
    public func editions(forFeed feedID: SmartFeedID) throws -> [PersonalEpisode] {
        let feedKey = feedID.rawValue
        var descriptor = FetchDescriptor<StoredPersonalEpisode>(
            predicate: #Predicate { $0.feedIdentifier == feedKey })
        descriptor.sortBy = [SortDescriptor(\.publishedAt, order: .reverse)]
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).compactMap {
            try? Self.decoder.decode(PersonalEpisode.self, from: $0.payload)
        }
    }

    /// Schreibt eine neue Ausgabe, nachdem der Wächter jede ihrer Folgen
    /// geprüft hat, alles in einem Schritt des Stores.
    ///
    /// `ticket` ist der Stand des Löschprotokolls beim Beginn des
    /// Zusammenstellens. Eine Folge, die seitdem gelöscht wurde, keine
    /// lebende Zeile mehr hat, ein Merkzeichen trägt oder deren Quelle fehlt,
    /// verliert ihre Stellen in der Ausgabe. Das geschieht auf demselben Weg
    /// wie beim späteren Löschen (`PersonalEpisodePublisher.removingSegments`),
    /// die Ausgabe sieht danach aus, als hätte es die Folge nie gegeben.
    public func commit(
        edition: PersonalEpisode, since ticket: RemovalLedger.Ticket, ledger: RemovalLedger = .shared
    ) throws -> EditionCommit {
        let feedKey = edition.feedID.rawValue
        var feedDescriptor = FetchDescriptor<StoredSmartFeed>(predicate: #Predicate { $0.identifier == feedKey })
        feedDescriptor.fetchLimit = 1
        guard try !modelContext.fetch(feedDescriptor).isEmpty else { return .feedMissing }

        // Jede Folge einmal, mit der Quelle, unter der die Ausgabe sie kannte.
        var dropped: Set<EpisodeID> = []
        var checked: Set<EpisodeID> = []
        for segment in edition.segments where checked.insert(segment.episodeID).inserted {
            let commitGuard = CommitGuard(
                episode: segment.episodeID, source: segment.sourceID, since: ticket, ledger: ledger)
            if case .stale = try verify(commitGuard) { dropped.insert(segment.episodeID) }
        }
        let identifier = edition.id.rawValue
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredPersonalEpisode>(predicate: #Predicate { $0.identifier == identifier }))
        guard let kept = dropped.isEmpty ? edition : PersonalEpisodePublisher().removingSegments(
            from: edition, where: { dropped.contains($0.episodeID) }) else {
            // Eine Zeile aus einem früheren Versuch geht mit.
            for row in existing { modelContext.delete(row) }
            if !existing.isEmpty { try modelContext.save() }
            return .nothingLeft(dropped: dropped)
        }
        try write(kept, over: existing)
        try modelContext.save()
        return .written(kept, dropped: dropped)
    }

    /// Ersetzt eine Ausgabe, die es schon gibt, etwa nachdem sie Stellen
    /// gelöschter Folgen verloren hat. Ohne Wächter: Die Stellen hat der
    /// Aufrufer gerade selbst herausgenommen, und eine Folge, die über
    /// iCloud noch nicht angekommen ist, soll hier nicht als gelöscht gelten.
    /// Gibt es die Zeile nicht mehr, etwa weil die Ausgabe inzwischen
    /// gelöscht wurde, bleibt es dabei.
    public func replace(edition: PersonalEpisode) throws {
        let identifier = edition.id.rawValue
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredPersonalEpisode>(predicate: #Predicate { $0.identifier == identifier }))
        guard !existing.isEmpty else { return }
        try write(edition, over: existing)
        try modelContext.save()
    }

    /// Löscht eine Ausgabe, alle Kopien ihrer Zeile.
    public func removeEdition(_ id: PersonalEpisodeID) throws {
        let identifier = id.rawValue
        let rows = try modelContext.fetch(
            FetchDescriptor<StoredPersonalEpisode>(predicate: #Predicate { $0.identifier == identifier }))
        guard !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Schreibt die Ausgabe in alle Kopien ihrer Zeile oder legt eine an.
    /// Alle Kopien, wie `save(editions:forFeed:)`: Doppelte, die das
    /// Bereinigen stehen lässt, sollen gleich bleiben.
    private func write(_ edition: PersonalEpisode, over rows: [StoredPersonalEpisode]) throws {
        let payload = try Self.encoder.encode(edition)
        guard !rows.isEmpty else {
            modelContext.insert(StoredPersonalEpisode(
                identifier: edition.id.rawValue, feedIdentifier: edition.feedID.rawValue,
                publishedAt: edition.publishedAt, payload: payload))
            return
        }
        for row in rows {
            row.publishedAt = edition.publishedAt
            row.payload = payload
        }
    }
}
#endif
