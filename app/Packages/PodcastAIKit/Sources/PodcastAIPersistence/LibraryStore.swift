//
//  LibraryStore.swift
//  PodcastAIPersistence
//
//  Der Zugang zur Datenbank, als `ModelActor`.
//
//  Die Regel, die hier durchgesetzt wird: **SwiftData-Objekte verlassen
//  diesen Actor nicht.** Nach außen gehen ausschließlich `Sendable`
//  Wertetypen aus `PodcastAICore`. Ein `@Model` über eine Actor-Grenze zu
//  reichen ist in Swift 6 nicht nur unschön, sondern ein Datenrennen.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore
import PodcastAIKnowledge
import PodcastAISmartFeeds

@ModelActor
public actor LibraryStore {

    /// Der öffentliche Weg, den Store zu bauen.
    ///
    /// `@ModelActor` erzeugt `init(modelContainer:)` mit modulinterner
    /// Sichtbarkeit. Der Typ ist `public`, sein Initialisierer nicht — aus
    /// einem App-Target heraus lässt er sich damit nicht bauen, und das
    /// fällt erst beim Übersetzen des App-Targets auf, nicht beim Paket.
    /// Diese Fabrik steht im selben Modul und darf den erzeugten
    /// Initialisierer deshalb aufrufen.
    public static func make(container: ModelContainer) -> LibraryStore {
        LibraryStore(modelContainer: container)
    }

    public static let schema = Schema([
        StoredSource.self, StoredEpisode.self, StoredMediaVersion.self,
        StoredTranscript.self, StoredSegment.self, StoredListeningState.self,
        StoredInterest.self, StoredEvidence.self, StoredHighlight.self,
        StoredSmartFeed.self, StoredPersonalEpisode.self, StoredKnowledgeTrail.self,
    ])

    /// Baut den Container.
    ///
    /// CloudKit ist hier **ausgeschaltet**. Der Plan sieht CKSyncEngine als
    /// einzigen Sync-Writer vor; SwiftDatas automatische Spiegelung parallel
    /// dazu wäre genau die Doppelung, die Constitution IX untersagt. Sie
    /// würde außerdem erzwingen, dass jedes Feld optional ist und keine
    /// Unique-Constraints existieren — beides brauchen wir hier.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Quellen

    public func upsert(source: Source) throws {
        let identifier = source.id.rawValue
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredSource>(predicate: #Predicate { $0.identifier == identifier })
        ).first

        let stored = existing ?? StoredSource(
            identifier: identifier, kind: source.kind, title: source.title
        )
        stored.title = source.title
        stored.author = source.author
        stored.feedURLString = source.feedURL?.absoluteString
        stored.websiteURLString = source.websiteURL?.absoluteString
        stored.artworkURLString = source.artworkURL?.absoluteString
        stored.isSubscribed = source.isSubscribed
        stored.canDownloadAudio = source.capabilities.audioDownload
        stored.hasPublisherTranscript = source.capabilities.publisherTranscript
        stored.embeddedPlayerOnly = source.capabilities.embeddedPlayerOnly
        stored.hasHistoricalCatalog = source.capabilities.historicalCatalog
        stored.limitationReason = source.capabilities.limitationReason
        stored.revisionValue = source.revision.value

        if existing == nil { modelContext.insert(stored) }
        try modelContext.save()
    }

    public func sources() throws -> [Source] {
        try modelContext.fetch(
            FetchDescriptor<StoredSource>(sortBy: [SortDescriptor(\.title)])
        ).map(\.snapshot)
    }

    // MARK: - Folgen

    /// Legt Folgen an oder aktualisiert sie.
    ///
    /// Die Deduplizierung läuft über die stabile Kennung aus der Feed-GUID.
    /// Ein zweites Einlesen desselben Feeds darf keine zweite Folge erzeugen —
    /// sonst wächst die Mediathek bei jedem Refresh.
    public func upsert(episodes: [Episode], forSource sourceID: SourceID) throws -> Int {
        let identifier = sourceID.rawValue
        guard let source = try modelContext.fetch(
            FetchDescriptor<StoredSource>(predicate: #Predicate { $0.identifier == identifier })
        ).first else { return 0 }

        var inserted = 0
        for episode in episodes {
            let episodeIdentifier = episode.id.rawValue
            // An die Quelle gebunden. Ohne diese Bedingung konnte eine
            // Kennungskollision dazu führen, dass ein fremder Feed eine
            // bestehende Folge übernimmt — samt Audioadresse. Aus „ein Feed
            // lügt“ wäre „eine vertraute Quelle sagt etwas, das sie nie
            // gesagt hat“ geworden.
            let existing = try modelContext.fetch(
                FetchDescriptor<StoredEpisode>(
                    predicate: #Predicate {
                        $0.identifier == episodeIdentifier
                            && $0.source?.identifier == identifier
                    }
                )
            ).first

            let stored = existing ?? StoredEpisode(identifier: episodeIdentifier, title: episode.title)
            stored.title = episode.title
            stored.summary = episode.summary
            stored.publishedAt = episode.publishedAt
            stored.declaredDurationMs = Int(episode.declaredDuration?.milliseconds ?? 0)
            stored.webPageURLString = episode.webPageURL?.absoluteString
            stored.audioURLString = episode.audioURL?.absoluteString
            stored.timedTranscriptURLString = episode.timedTranscriptURL?.absoluteString
            stored.artworkURLString = episode.artworkURL?.absoluteString
            stored.source = source

            if existing == nil {
                modelContext.insert(stored)
                inserted += 1
            }
        }
        try modelContext.save()
        return inserted
    }

    public func episodes(forSource sourceID: SourceID, limit: Int = 200) throws -> [Episode] {
        // Als Optional deklariert: `#Predicate` vergleicht `String?` gegen
        // `String` nicht — die implizite Promotion, die normaler Swift-Code
        // macht, gibt es in der Makroexpansion nicht.
        let identifier: String? = sourceID.rawValue
        var descriptor = FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.source?.identifier == identifier },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    // MARK: - Hörzustand

    /// Schreibt Hörereignisse.
    ///
    /// Bewusst hier und nicht im Player: der Player meldet, was erklungen
    /// ist; die Wahrheit über den Hörzustand entsteht an einer Stelle, damit
    /// Originalfolge, Chat-Fokus und persönliche Ausgabe nicht auseinander
    /// laufen können.
    public func record(_ events: [LedgerEvent]) throws {
        for event in events {
            let identifier = event.mediaVersionID.rawValue
            let existing = try modelContext.fetch(
                FetchDescriptor<StoredListeningState>(
                    predicate: #Predicate { $0.mediaVersionIdentifier == identifier }
                )
            ).first

            let stored = existing ?? StoredListeningState(mediaVersionIdentifier: identifier)
            var state = stored.snapshot
            state.apply(event)
            stored.apply(state)
            if existing == nil { modelContext.insert(stored) }
        }
        try modelContext.save()
    }

    /// Lädt den gemeinsamen Hörzustand.
    ///
    /// `ListeningLedger` ist ein Wertetyp und verlässt den Actor gefahrlos —
    /// genau dafür ist die Trennung von Modell und Domäne da.
    public func ledger() throws -> ListeningLedger {
        let states = try modelContext.fetch(FetchDescriptor<StoredListeningState>())
        var result: [MediaVersionID: MediaListeningState] = [:]
        for stored in states {
            let snapshot = stored.snapshot
            result[snapshot.mediaVersionID] = snapshot
        }
        return ListeningLedger(states: result)
    }

    // MARK: - Interessen

    public func interestProfile(learningEnabled: Bool) throws -> InterestProfile {
        let interests = try modelContext.fetch(
            FetchDescriptor<StoredInterest>(sortBy: [SortDescriptor(\.createdAt)])
        ).map(\.snapshot)
        return InterestProfile(interests: interests, learningEnabled: learningEnabled)
    }

    public func upsert(interest: Interest) throws {
        let identifier = interest.id.rawValue
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredInterest>(predicate: #Predicate { $0.identifier == identifier })
        ).first

        let stored = existing ?? StoredInterest(identifier: identifier, label: interest.label)
        stored.label = interest.label
        stored.kindRaw = interest.kind.rawValue
        stored.originRaw = interest.origin.rawValue
        stored.keywords = interest.keywords
        stored.expiresAt = interest.expiresAt
        if existing == nil { modelContext.insert(stored) }
        try modelContext.save()
    }

    public func removeInterest(_ id: InterestID) throws {
        let identifier = id.rawValue
        for stored in try modelContext.fetch(
            FetchDescriptor<StoredInterest>(predicate: #Predicate { $0.identifier == identifier })
        ) {
            modelContext.delete(stored)
        }
        try modelContext.save()
    }

    // MARK: - Belege

    public func store(evidence: [Evidence]) throws {
        for item in evidence {
            let identifier = item.id.rawValue
            let existing = try modelContext.fetch(
                FetchDescriptor<StoredEvidence>(
                    predicate: #Predicate { $0.identifier == identifier }
                )
            ).first
            // Belege sind unveränderlich. Existiert einer bereits, bleibt er
            // wie er ist — eine Neuanalyse erzeugt eine neue Revision und
            // damit eine neue Kennung.
            guard existing == nil else { continue }

            let stored = StoredEvidence(identifier: identifier)
            stored.mediaVersionIdentifier = item.mediaVersionID.rawValue
            stored.episodeIdentifier = item.episodeID.rawValue
            stored.sourceIdentifier = item.sourceID.rawValue
            stored.transcriptIdentifier = item.transcriptID.rawValue
            stored.transcriptRevisionValue = item.transcriptRevision.value
            stored.hasTiming = item.range != nil
            stored.startMs = Int(item.range?.start.milliseconds ?? 0)
            stored.endMs = Int(item.range?.end.milliseconds ?? 0)
            stored.quotedText = item.quotedText
            stored.attributedSpeaker = item.attributedSpeaker
            modelContext.insert(stored)
        }
        try modelContext.save()
    }

    public func evidence(ids: [EvidenceID]) throws -> [EvidenceID: Evidence] {
        let identifiers = Set(ids.map(\.rawValue))
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredEvidence>(
                predicate: #Predicate { identifiers.contains($0.identifier) }
            )
        )
        return Dictionary(uniqueKeysWithValues: stored.map { ($0.snapshot.id, $0.snapshot) })
    }

    /// Belege aller Quellen, die für einen Themenfeed infrage kommen.
    public func evidenceForAnalyzedEpisodes(limit: Int = 500) throws -> [Evidence] {
        var descriptor = FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.hasTiming == true }
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    /// Folgen zu einer Menge von Kennungen.
    ///
    /// Der Planungskontext braucht sie aus zwei Gründen: für den echten
    /// Folgentitel statt eines Platzhalters, und für
    /// `currentMediaVersionID` — ohne die kann er nicht erkennen, dass ein
    /// Beleg auf eine überholte Fassung zeigt.
    public func episodes(ids: [EpisodeID]) throws -> [Episode] {
        let identifiers = Set(ids.map(\.rawValue))
        guard !identifiers.isEmpty else { return [] }
        return try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(
                predicate: #Predicate { identifiers.contains($0.identifier) }
            )
        ).map(\.snapshot)
    }

    /// Folgen- und Quellentitel zu einer Menge von Folgen, in einem Zug.
    ///
    /// Die Oberfläche braucht zu jedem Beleg beide Titel. Sie je Beleg
    /// einzeln zu holen wären bei 500 Belegen 500 Abfragen; hier ist es eine.
    public func titles(forEpisodes episodeIDs: [EpisodeID]) throws -> [EpisodeID: EpisodeTitles] {
        let identifiers = Set(episodeIDs.map(\.rawValue))
        guard !identifiers.isEmpty else { return [:] }
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(
                predicate: #Predicate { identifiers.contains($0.identifier) }
            )
        )
        var result: [EpisodeID: EpisodeTitles] = [:]
        for episode in stored {
            result[EpisodeID(rawValue: episode.identifier)] = EpisodeTitles(
                episode: episode.title,
                source: episode.source?.title ?? "Unbekannte Quelle"
            )
        }
        return result
    }

    /// Zwei Titel, die immer zusammen gebraucht werden.
    public struct EpisodeTitles: Sendable {
        public let episode: String
        public let source: String
    }

    // MARK: - Was der Nutzer selbst anlegt

    //  Themenfeeds, persönliche Ausgaben, Merkzettel und geparkte Fragen
    //  lagen bisher nur im Speicher und waren beim nächsten Start weg.
    //  Gespeichert wird der vollständige Wert als JSON; die Felder, nach
    //  denen gesucht wird, stehen zusätzlich als Spalten daneben (siehe
    //  `Models.swift`).

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Stabile Reihenfolge: zwei gleiche Werte ergeben dasselbe JSON.
        // Sonst sähe jeder Speichervorgang nach einer Änderung aus.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func save(smartFeeds: [SmartPodcastFeed]) throws {
        let keep = Set(smartFeeds.map(\.id.rawValue))
        var existing: [String: StoredSmartFeed] = [:]
        // Ein Durchlauf: behalten oder löschen. Ein zweiter `fetch` nach
        // dem Löschen sähe die gelöschten Zeilen noch.
        for row in try modelContext.fetch(FetchDescriptor<StoredSmartFeed>()) {
            if keep.contains(row.identifier) {
                existing[row.identifier] = row
            } else {
                // Was der Nutzer gelöscht hat, verschwindet auch hier.
                modelContext.delete(row)
            }
        }

        for feed in smartFeeds {
            let payload = try Self.encoder.encode(feed)
            if let row = existing[feed.id.rawValue] {
                row.title = feed.title
                row.payload = payload
            } else {
                modelContext.insert(StoredSmartFeed(
                    identifier: feed.id.rawValue, title: feed.title, payload: payload))
            }
        }
        try modelContext.save()
    }

    public func smartFeeds() throws -> [SmartPodcastFeed] {
        var descriptor = FetchDescriptor<StoredSmartFeed>()
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        return try modelContext.fetch(descriptor).compactMap {
            // Ein einzelner unlesbarer Eintrag darf nicht die ganze Liste
            // verschlucken — etwa nach einer Formatänderung.
            try? Self.decoder.decode(SmartPodcastFeed.self, from: $0.payload)
        }
    }

    public func save(editions: [PersonalEpisode], forFeed feedID: SmartFeedID) throws {
        let feedKey = feedID.rawValue
        let keep = Set(editions.map(\.id.rawValue))
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredPersonalEpisode>(
                predicate: #Predicate { $0.feedIdentifier == feedKey }
            )
        )
        var existing: [String: StoredPersonalEpisode] = [:]
        for row in stored {
            if keep.contains(row.identifier) {
                existing[row.identifier] = row
            } else {
                modelContext.delete(row)
            }
        }
        for episode in editions {
            let payload = try Self.encoder.encode(episode)
            if let row = existing[episode.id.rawValue] {
                row.publishedAt = episode.publishedAt
                row.payload = payload
            } else {
                modelContext.insert(StoredPersonalEpisode(
                    identifier: episode.id.rawValue,
                    feedIdentifier: feedKey,
                    publishedAt: episode.publishedAt,
                    payload: payload))
            }
        }
        try modelContext.save()
    }

    /// Alle Ausgaben, nach Feed gruppiert — so, wie die Oberfläche sie hält.
    public func editions() throws -> [SmartFeedID: [PersonalEpisode]] {
        var descriptor = FetchDescriptor<StoredPersonalEpisode>()
        descriptor.sortBy = [SortDescriptor(\.publishedAt, order: .reverse)]
        var result: [SmartFeedID: [PersonalEpisode]] = [:]
        for row in try modelContext.fetch(descriptor) {
            guard let episode = try? Self.decoder.decode(
                PersonalEpisode.self, from: row.payload) else { continue }
            result[SmartFeedID(rawValue: row.feedIdentifier), default: []].append(episode)
        }
        return result
    }

    public func save(trails: [KnowledgeTrail]) throws {
        let keep = Set(trails.map(\.id.rawValue))
        let stored = try modelContext.fetch(FetchDescriptor<StoredKnowledgeTrail>())
        var existing: [String: StoredKnowledgeTrail] = [:]
        for row in stored {
            if keep.contains(row.identifier) {
                existing[row.identifier] = row
            } else {
                modelContext.delete(row)
            }
        }
        for trail in trails {
            let payload = try Self.encoder.encode(trail)
            if let row = existing[trail.id.rawValue] {
                row.question = trail.question
                row.payload = payload
            } else {
                modelContext.insert(StoredKnowledgeTrail(
                    identifier: trail.id.rawValue, question: trail.question,
                    parkedAt: trail.parkedAt, payload: payload))
            }
        }
        try modelContext.save()
    }

    public func trails() throws -> [KnowledgeTrail] {
        var descriptor = FetchDescriptor<StoredKnowledgeTrail>()
        descriptor.sortBy = [SortDescriptor(\.parkedAt, order: .reverse)]
        return try modelContext.fetch(descriptor).compactMap {
            try? Self.decoder.decode(KnowledgeTrail.self, from: $0.payload)
        }
    }

    public func save(highlights: [Highlight]) throws {
        let keep = Set(highlights.map(\.id.rawValue))
        let stored = try modelContext.fetch(FetchDescriptor<StoredHighlight>())
        var existing: [String: StoredHighlight] = [:]
        for row in stored {
            if keep.contains(row.identifier) {
                existing[row.identifier] = row
            } else {
                modelContext.delete(row)
            }
        }
        for highlight in highlights {
            let payload = try Self.encoder.encode(highlight)
            if let row = existing[highlight.id.rawValue] {
                row.note = highlight.note
                row.payload = payload
            } else {
                let row = StoredHighlight(
                    identifier: highlight.id.rawValue,
                    evidenceIdentifier: highlight.evidenceID.rawValue)
                row.note = highlight.note
                row.createdAt = highlight.capturedAt
                row.payload = payload
                modelContext.insert(row)
            }
        }
        try modelContext.save()
    }

    public func highlights() throws -> [Highlight] {
        var descriptor = FetchDescriptor<StoredHighlight>()
        descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        return try modelContext.fetch(descriptor).compactMap { row in
            guard let payload = row.payload else { return nil }
            return try? Self.decoder.decode(Highlight.self, from: payload)
        }
    }
}
#endif
