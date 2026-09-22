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
import CoreData
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

    public static let modelTypes: [any PersistentModel.Type] = [
        StoredSource.self, StoredEpisode.self, StoredMediaVersion.self,
        StoredTranscript.self, StoredSegment.self, StoredListeningState.self,
        StoredInterest.self, StoredEvidence.self, StoredHighlight.self,
        StoredSmartFeed.self, StoredPersonalEpisode.self, StoredKnowledgeTrail.self,
        StoredFact.self,
    ]

    public static let schema = Schema(modelTypes)

    /// Legt das CloudKit-Schema für alle Modelle in der Entwicklungsumgebung
    /// an. Nur für Entwickler: danach wird es in der CloudKit-Konsole nach
    /// „Production“ übertragen, damit TestFlight- und App-Store-Builds
    /// abgleichen können.
    public static func initializeCloudKitSchema(containerIdentifier: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: containerIdentifier)
        description.shouldAddStoreAsynchronously = false
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes) else {
            throw CocoaError(.featureUnsupported)
        }
        let container = NSPersistentCloudKitContainer(name: "PodcastAI", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        try container.initializeCloudKitSchema()
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }

    /// Baut den Container.
    ///
    /// Mit `sync` spiegelt SwiftData die Datenbank in die private
    /// iCloud-Datenbank des Nutzers. Welcher Container das ist, steht in den
    /// Entitlements der App. Fehlt dort iCloud, bleibt der Speicher lokal.
    /// Audiodateien liegen ausserhalb der Datenbank und synchronisieren sich
    /// nicht; jedes Gerät lädt den Ton selbst, Transkripte, Belege, Fakten,
    /// Hörzustand und alles Selbstangelegte kommen über iCloud.
    ///
    /// Weil CloudKit keine eindeutigen Schlüssel kennt, kann derselbe
    /// Datensatz nach dem Abgleich zweier Geräte doppelt vorliegen. Das
    /// bereinigt ``removeDuplicates()``.
    public static func makeContainer(inMemory: Bool = false, sync: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: (sync && !inMemory) ? .automatic : .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Öffnet den gespeicherten Container. Lässt sich ein Speicher aus einer
    /// älteren Testversion nicht mehr öffnen, wird er beiseitegelegt und neu
    /// angelegt, statt die App ohne Speicher starten zu lassen.
    public static func openPersistentContainer(sync: Bool) throws -> ModelContainer {
        do {
            return try makeContainer(sync: sync)
        } catch {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let stamp = Int(Date().timeIntervalSince1970)
            for name in ["default.store", "default.store-shm", "default.store-wal"] {
                let url = base.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try? FileManager.default.moveItem(
                    at: url, to: base.appendingPathComponent("\(name).alt-\(stamp)"))
            }
            return try makeContainer(sync: sync)
        }
    }

    /// Entfernt doppelte Datensätze, die beim Abgleich zweier Geräte
    /// entstehen können. Behalten wird jeweils der erste.
    public func removeDuplicates() throws {
        func dedupe<T: PersistentModel>(_ type: T.Type, key: (T) -> String) throws {
            var seen: Set<String> = []
            for row in try modelContext.fetch(FetchDescriptor<T>()) {
                let value = key(row)
                if value.isEmpty { continue }
                if seen.contains(value) { modelContext.delete(row) } else { seen.insert(value) }
            }
        }
        try dedupe(StoredSource.self) { $0.identifier }
        try dedupe(StoredEpisode.self) { $0.identifier }
        try dedupe(StoredMediaVersion.self) { $0.identifier }
        try dedupe(StoredTranscript.self) { $0.identifier }
        try dedupe(StoredSegment.self) { $0.identifier }
        try dedupe(StoredListeningState.self) { $0.mediaVersionIdentifier }
        try dedupe(StoredInterest.self) { $0.identifier }
        try dedupe(StoredEvidence.self) { $0.identifier }
        try dedupe(StoredHighlight.self) { $0.identifier }
        try dedupe(StoredSmartFeed.self) { $0.identifier }
        try dedupe(StoredPersonalEpisode.self) { $0.identifier }
        try dedupe(StoredKnowledgeTrail.self) { $0.identifier }
        try dedupe(StoredFact.self) { $0.identifier }
        try modelContext.save()
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
        stored.languageCode = source.language
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
            // Gelöscht bleibt gelöscht, auch wenn der Feed die Folge weiter führt.
            if existing?.removedAt != nil { continue }

            let stored = existing ?? StoredEpisode(identifier: episodeIdentifier, title: episode.title)
            stored.title = episode.title
            stored.summary = episode.summary
            stored.publishedAt = episode.publishedAt
            stored.declaredDurationMs = Int(episode.declaredDuration?.milliseconds ?? 0)
            stored.webPageURLString = episode.webPageURL?.absoluteString
            stored.audioURLString = episode.audioURL?.absoluteString
            stored.timedTranscriptURLString = episode.timedTranscriptURL?.absoluteString
            stored.artworkURLString = episode.artworkURL?.absoluteString
            stored.chaptersData = episode.publisherChapters.isEmpty
                ? nil : try? JSONEncoder().encode(episode.publisherChapters)
            stored.chaptersURLString = episode.chaptersURL?.absoluteString
            stored.shownotesHTML = episode.shownotesHTML
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
            predicate: #Predicate { $0.source?.identifier == identifier && $0.removedAt == nil },
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

    /// Sichert Medienfassung und Transkript einer erschlossenen Folge.
    ///
    /// Beides wurde bisher nie geschrieben: `StoredMediaVersion`,
    /// `StoredTranscript` und `StoredSegment` standen im Schema und blieben
    /// leer. Nur die Belege überlebten — und damit ging jedes Mal verloren,
    /// was **zwischen** den Belegen steht. Eine Passage neu zu lesen hiesse
    /// dann, die Datei noch einmal durch die Spracherkennung zu schicken.
    ///
    /// Die Medienfassung wird an die Folge gehängt. Ohne diese Verbindung
    /// kann der Planer nicht erkennen, dass ein Beleg auf eine überholte
    /// Fassung zeigt: `Episode.currentMediaVersionID` bliebe leer.
    public func save(
        transcript: Transcript, media: MediaVersion, forEpisode episodeID: EpisodeID
    ) throws {
        let mediaKey = media.id.rawValue
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredMediaVersion>(
                predicate: #Predicate { $0.identifier == mediaKey }
            )
        ).first ?? {
            let fresh = StoredMediaVersion(identifier: mediaKey)
            modelContext.insert(fresh)
            return fresh
        }()

        stored.remoteURLString = media.remoteURL?.absoluteString
        stored.localRelativePath = media.localRelativePath
        stored.byteCount = Int(media.byteCount ?? 0)
        stored.contentHash = media.contentHash
        stored.durationMs = Int(media.duration?.milliseconds ?? 0)
        stored.mimeType = media.mimeType
        stored.supportsExactSeeking = media.supportsExactSeeking

        let episodeKey = episodeID.rawValue
        let episode = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(
                predicate: #Predicate { $0.identifier == episodeKey }
            )
        ).first
        stored.episode = episode
        // Die aktuelle Fassung der Folge ist die zuletzt erschlossene.
        episode?.currentMediaVersionIdentifier = mediaKey

        let transcriptKey = transcript.id.rawValue
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredTranscript>(
                predicate: #Predicate { $0.identifier == transcriptKey }
            )
        ).first
        // Ein Transkript ist wie ein Beleg unveränderlich: eine Neuanalyse
        // erzeugt eine neue Revision und damit eine neue Kennung. Dasselbe
        // noch einmal zu schreiben hiesse, Segmente zu verdoppeln.
        if let existing {
            existing.mediaVersion = stored
            try modelContext.save()
            return
        }

        let row = StoredTranscript(identifier: transcriptKey)
        row.revisionValue = transcript.revision.value
        row.originRaw = transcript.origin.rawValue
        row.locale = transcript.locale
        row.createdAt = transcript.createdAt
        row.analyzedRangesFlat = StoredTranscript.flat(from: transcript.analyzedRanges)
        row.untimedText = transcript.untimedText
        row.mediaVersion = stored
        modelContext.insert(row)

        for segment in transcript.segments {
            let piece = StoredSegment(
                identifier: segment.id.rawValue,
                startMs: Int(segment.range.start.milliseconds),
                endMs: Int(segment.range.end.milliseconds),
                text: segment.text)
            piece.speakerLabel = segment.speakerLabel
            piece.transcript = row
            modelContext.insert(piece)
        }
        try modelContext.save()
    }

    /// Das Transkript einer Medienfassung, mit Segmenten.
    public func transcript(forMedia mediaVersionID: MediaVersionID) throws -> Transcript? {
        let key = mediaVersionID.rawValue
        var descriptor = FetchDescriptor<StoredTranscript>(
            predicate: #Predicate { $0.mediaVersion?.identifier == key }
        )
        descriptor.sortBy = [SortDescriptor(\.revisionValue, order: .reverse)]
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.snapshot
    }

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
        // Nach einem Abgleich zweier Geräte kann ein Beleg doppelt vorliegen.
        return Dictionary(stored.map { ($0.snapshot.id, $0.snapshot) }, uniquingKeysWith: { first, _ in first })
    }

    /// Die Belege einer Folge, nach Zeit sortiert.
    public func evidence(forEpisode episodeID: EpisodeID) throws -> [Evidence] {
        let identifier = episodeID.rawValue
        let descriptor = FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.episodeIdentifier == identifier },
            sortBy: [SortDescriptor(\.startMs)]
        )
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    /// Die Folgen, zu denen es schon Belege mit Zeitmarken gibt.
    public func analyzedEpisodeIDs() throws -> Set<EpisodeID> {
        var descriptor = FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.hasTiming == true }
        )
        descriptor.propertiesToFetch = [\.episodeIdentifier]
        let stored = try modelContext.fetch(descriptor)
        return Set(stored.map { EpisodeID(rawValue: $0.episodeIdentifier) })
    }

    // MARK: - Entfernen

    /// Was beim Entfernen gelöscht wurde. Die Audiodateien selbst liegen
    /// ausserhalb der Datenbank; der Aufrufer löscht sie anhand dieser Liste.
    public struct RemovalReport: Sendable, Equatable {
        public var mediaVersionIDs: [MediaVersionID] = []
        public var evidenceIDs: [EvidenceID] = []
        public var episodeIDs: [EpisodeID] = []
    }

    /// Löscht eine Folge mit allem, was aus ihr entstanden ist: Transkript,
    /// Belege, Fakten, Hörzustand und gemerkte Stellen. Die Zeile der Folge
    /// bleibt als Merkzeichen, damit der Feed sie nicht wieder anlegt.
    public func removeEpisode(_ episodeID: EpisodeID) throws -> RemovalReport {
        var report = RemovalReport()
        try purgeEpisode(episodeID.rawValue, keepTombstone: true, into: &report)
        try modelContext.save()
        return report
    }

    /// Bestellt eine Quelle ab und löscht alle ihre Folgen samt Daten.
    public func removeSource(_ sourceID: SourceID) throws -> RemovalReport {
        var report = RemovalReport()
        let key = sourceID.rawValue
        let sources = try modelContext.fetch(
            FetchDescriptor<StoredSource>(predicate: #Predicate { $0.identifier == key }))
        for source in sources {
            for episode in source.episodes ?? [] {
                try purgeEpisode(episode.identifier, keepTombstone: false, into: &report)
            }
            modelContext.delete(source)
        }
        try modelContext.save()
        return report
    }

    private func purgeEpisode(_ key: String, keepTombstone: Bool, into report: inout RemovalReport) throws {
        let episodes = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.identifier == key }))
        var mediaKeys: Set<String> = []
        for episode in episodes {
            for media in episode.mediaVersions ?? [] {
                mediaKeys.insert(media.identifier)
                modelContext.delete(media)   // Transkripte und Segmente hängen daran
            }
            if let current = episode.currentMediaVersionIdentifier { mediaKeys.insert(current) }
            if let audio = episode.audioURLString {
                mediaKeys.insert(MediaVersionID(stable: audio).rawValue)
            }
            if keepTombstone {
                episode.removedAt = Date()
                episode.currentMediaVersionIdentifier = nil
                episode.mediaVersions = []
            } else {
                modelContext.delete(episode)
            }
            report.episodeIDs.append(EpisodeID(rawValue: key))
        }

        let evidence = try modelContext.fetch(
            FetchDescriptor<StoredEvidence>(predicate: #Predicate { $0.episodeIdentifier == key }))
        let evidenceKeys = Set(evidence.map(\.identifier))
        for row in evidence {
            mediaKeys.insert(row.mediaVersionIdentifier)
            modelContext.delete(row)
        }
        report.evidenceIDs += evidenceKeys.map(EvidenceID.init(rawValue:))

        for fact in try modelContext.fetch(
            FetchDescriptor<StoredFact>(predicate: #Predicate { $0.episodeIdentifier == key })) {
            modelContext.delete(fact)
        }
        if !evidenceKeys.isEmpty {
            for highlight in try modelContext.fetch(FetchDescriptor<StoredHighlight>())
            where evidenceKeys.contains(highlight.evidenceIdentifier) {
                modelContext.delete(highlight)
            }
        }
        for mediaKey in mediaKeys where !mediaKey.isEmpty {
            for state in try modelContext.fetch(FetchDescriptor<StoredListeningState>(
                predicate: #Predicate { $0.mediaVersionIdentifier == mediaKey })) {
                modelContext.delete(state)
            }
            for transcript in try modelContext.fetch(FetchDescriptor<StoredTranscript>(
                predicate: #Predicate { $0.mediaVersion?.identifier == mediaKey })) {
                modelContext.delete(transcript)
            }
            for media in try modelContext.fetch(FetchDescriptor<StoredMediaVersion>(
                predicate: #Predicate { $0.identifier == mediaKey })) {
                modelContext.delete(media)
            }
        }
        report.mediaVersionIDs += mediaKeys.filter { !$0.isEmpty }.sorted().map(MediaVersionID.init(rawValue:))
    }

    /// Merkt, dass die Audiodatei einer Fassung gelöscht wurde. Transkript,
    /// Belege, Fakten und Hörzustand bleiben.
    public func markAudioRemoved(_ mediaVersionIDs: [MediaVersionID]) throws {
        for id in mediaVersionIDs {
            let key = id.rawValue
            for media in try modelContext.fetch(FetchDescriptor<StoredMediaVersion>(
                predicate: #Predicate { $0.identifier == key })) {
                media.localRelativePath = nil
            }
        }
        try modelContext.save()
    }

    /// Die Medienfassungen einer Folge.
    public func mediaVersionIDs(forEpisode episodeID: EpisodeID) throws -> [MediaVersionID] {
        let key = episodeID.rawValue
        var keys: Set<String> = []
        for episode in try modelContext.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.identifier == key })) {
            for media in episode.mediaVersions ?? [] { keys.insert(media.identifier) }
            if let current = episode.currentMediaVersionIdentifier { keys.insert(current) }
            if let audio = episode.audioURLString { keys.insert(MediaVersionID(stable: audio).rawValue) }
        }
        for row in try modelContext.fetch(FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.episodeIdentifier == key })) {
            keys.insert(row.mediaVersionIdentifier)
        }
        return keys.filter { !$0.isEmpty }.sorted().map(MediaVersionID.init(rawValue:))
    }

    /// Nur für Tests: legt einen Beleg ohne Prüfung auf Doppelte an, so wie
    /// es der iCloud-Abgleich zweier Geräte tun kann.
    func insertDuplicateEvidenceForTesting(_ item: Evidence) throws {
        let stored = StoredEvidence(identifier: item.id.rawValue)
        stored.mediaVersionIdentifier = item.mediaVersionID.rawValue
        stored.episodeIdentifier = item.episodeID.rawValue
        stored.sourceIdentifier = item.sourceID.rawValue
        stored.startMs = Int(item.range?.start.milliseconds ?? 0)
        stored.endMs = Int(item.range?.end.milliseconds ?? 0)
        stored.quotedText = item.quotedText
        modelContext.insert(stored)
        try modelContext.save()
    }

    // MARK: - Transkript und Fakten je Folge

    /// Das jüngste Transkript einer Folge, über alle ihre Fassungen.
    public func transcript(forEpisode episodeID: EpisodeID) throws -> Transcript? {
        for id in try mediaVersionIDs(forEpisode: episodeID) {
            if let transcript = try transcript(forMedia: id), !transcript.segments.isEmpty {
                return transcript
            }
        }
        return nil
    }

    public func save(facts: [EpisodeFact], forEpisode episodeID: EpisodeID) throws {
        let key = episodeID.rawValue
        for row in try modelContext.fetch(FetchDescriptor<StoredFact>(
            predicate: #Predicate { $0.episodeIdentifier == key })) {
            modelContext.delete(row)
        }
        for fact in facts {
            let row = StoredFact(identifier: fact.id)
            row.episodeIdentifier = fact.episodeID.rawValue
            row.sourceIdentifier = fact.sourceID.rawValue
            row.evidenceIdentifier = fact.evidenceID.rawValue
            row.mediaVersionIdentifier = fact.mediaVersionID.rawValue
            row.statement = fact.statement
            row.startMs = Int(fact.range.start.milliseconds)
            row.endMs = Int(fact.range.end.milliseconds)
            row.modelTier = fact.modelTier
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    public func facts(forEpisode episodeID: EpisodeID) throws -> [EpisodeFact] {
        let key = episodeID.rawValue
        return try modelContext.fetch(FetchDescriptor<StoredFact>(
            predicate: #Predicate { $0.episodeIdentifier == key },
            sortBy: [SortDescriptor(\.startMs)])).map(\.snapshot)
    }

    /// Alle Fakten, etwa für den Chat über alle Folgen.
    public func allFacts(limit: Int = 2_000) throws -> [EpisodeFact] {
        var descriptor = FetchDescriptor<StoredFact>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.snapshot)
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
        // Gelöschte Folgen bleiben als Merkzeichen stehen. Sie gehören nicht
        // zurück in „Als Nächstes“ oder in einen Hörplan.
        return try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(
                predicate: #Predicate { identifiers.contains($0.identifier) && $0.removedAt == nil }
            )
        ).map(\.snapshot)
    }

    /// Die gelöschten Folgen, deren Merkzeichen noch da sind. Ein Gerät,
    /// das die Löschung nur über iCloud erfährt, räumt damit seine eigenen
    /// Audiodateien und Listen auf.
    public func removedEpisodes() throws -> [Episode] {
        try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.removedAt != nil })
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
                source: episode.source?.title ?? "Unbekannte Quelle",
                publishedAt: episode.publishedAt
            )
        }
        return result
    }

    /// Was eine Ausgabe über ihre Bestandteile schreiben muss.
    ///
    /// Das Erscheinungsdatum gehört dazu: in den Shownotes steht, wann die
    /// **Originalfolge** erschienen ist, nicht wann die Ausgabe entstand.
    public struct EpisodeTitles: Sendable {
        public let episode: String
        public let source: String
        public let publishedAt: Date?
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
