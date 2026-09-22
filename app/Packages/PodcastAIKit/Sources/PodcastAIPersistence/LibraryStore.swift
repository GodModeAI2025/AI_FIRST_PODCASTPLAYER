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
        let configuration = persistentConfiguration(inMemory: inMemory, sync: sync)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func persistentConfiguration(inMemory: Bool = false, sync: Bool) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: (sync && !inMemory) ? .automatic : .none
        )
    }

    /// Ein Container an einer festen Adresse. Für Tests, die eine Datei
    /// brauchen, ohne den echten Speicher der App anzufassen.
    static func makeContainer(at url: URL, sync: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema, url: url, cloudKitDatabase: sync ? .automatic : .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Öffnet den gespeicherten Container. Die Datei wird dabei nie verändert
    /// oder verschoben, auch wenn das Öffnen scheitert.
    public static func openPersistentContainer(sync: Bool) throws -> ModelContainer {
        try makeContainer(sync: sync)
    }

    /// Der geöffnete lokale Speicher und, falls nötig, ein Hinweis für den Nutzer.
    public struct LocalContainer {
        public let container: ModelContainer
        /// Gesetzt, wenn der alte Speicher beiseitegelegt werden musste.
        public let recoveryNote: String?
    }

    /// Öffnet den Speicher ohne Abgleich. Der letzte Weg, nachdem
    /// ``openPersistentContainer(sync:)`` mit Abgleich gescheitert ist.
    ///
    /// Beiseitegelegt wird der alte Speicher nur, wenn auch dieses Öffnen
    /// scheitert und der Fehler zeigt, dass die Datei zu diesem Modell nicht
    /// passt und sich nicht umwandeln lässt. Bei jedem anderen Fehler, etwa
    /// fehlenden Rechten, einer gesperrten Datei oder einem Problem mit
    /// CloudKit, bleibt die Datei, wo sie ist, und der Fehler geht an den
    /// Aufrufer. Eine leere Mediathek wäre dort schlimmer als ein Hinweis.
    public static func openLocalContainer() throws -> LocalContainer {
        let url = persistentConfiguration(sync: false).url
        return try openLocalContainer(at: url) { try makeContainer(sync: false) }
    }

    static func openLocalContainer(
        at url: URL, open: () throws -> ModelContainer
    ) throws -> LocalContainer {
        do {
            return LocalContainer(container: try open(), recoveryNote: nil)
        } catch {
            guard isIncompatibleStore(error, at: url) else { throw error }
            let backup = try moveStoreAside(at: url)
            let container = try open()
            return LocalContainer(
                container: container,
                recoveryNote: "Die gespeicherte Mediathek passt nicht zu dieser Version der App "
                    + "und liess sich nicht übernehmen. Die alte Datei liegt unverändert als "
                    + "\(backup.lastPathComponent) im App-Ordner. Die App beginnt mit einem leeren Speicher.")
        }
    }

    /// Fehlercodes von Core Data, die sagen: Datei und Modell passen nicht
    /// zusammen, und eine Umwandlung ist gescheitert. Werte aus
    /// `CoreDataErrors.h`. Bewusst nicht dabei sind 134020 (auch fehlende
    /// Rechte), 134080 (Öffnen allgemein) und 134180 (SQLite allgemein).
    static let incompatibleStoreCodes: Set<Int> = [
        134100, 134110, 134111, 134120, 134130, 134140,
        134150, 134160, 134170, 134190, 134505, 134506,
    ]

    /// Ist der Fehler einer, bei dem die Datei zu diesem Modell nicht passt?
    ///
    /// SwiftData meldet eine gescheiterte Umwandlung oft nur als allgemeines
    /// `loadIssueModelContainer`. Dann entscheiden die Metadaten der Datei:
    /// Lassen sie sich lesen und passen nicht zum Modell, ist die Datei aus
    /// einer anderen Version. Lassen sie sich nicht lesen, wird nichts
    /// verschoben, denn das kann auch eine gesperrte Datei sein.
    static func isIncompatibleStore(_ error: any Error, at url: URL?) -> Bool {
        if isIncompatibleStoreError(error) { return true }
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: url, options: nil),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes)
        else { return false }
        return !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    static func isIncompatibleStoreError(_ error: any Error) -> Bool {
        switch error {
        case SwiftDataError.backwardMigration, SwiftDataError.unknownSchema:
            return true
        default:
            break
        }
        if #available(iOS 27, macOS 27, *), case SwiftDataError.unknownDataStoreSchema = error {
            return true
        }
        return containsIncompatibleCode(error as NSError, depth: 0)
    }

    private static func containsIncompatibleCode(_ error: NSError, depth: Int) -> Bool {
        if error.domain == NSCocoaErrorDomain, incompatibleStoreCodes.contains(error.code) { return true }
        guard depth < 8 else { return false }
        var underlying: [NSError] = []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError { underlying.append(single) }
        if let many = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { underlying += many }
        if let detailed = error.userInfo[NSDetailedErrorsKey] as? [NSError] { underlying += detailed }
        return underlying.contains { containsIncompatibleCode($0, depth: depth + 1) }
    }

    /// Legt die Speicherdatei samt Begleitdateien unter neuem Namen daneben.
    /// Gibt die Adresse der beiseitegelegten Hauptdatei zurück.
    static func moveStoreAside(at url: URL) throws -> URL {
        let manager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let support = "." + url.deletingPathExtension().lastPathComponent + "_SUPPORT"
        for part in [name, name + "-shm", name + "-wal", support] {
            let source = folder.appendingPathComponent(part)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.moveItem(at: source, to: folder.appendingPathComponent("\(part).alt-\(stamp)"))
        }
        return folder.appendingPathComponent("\(name).alt-\(stamp)")
    }

    /// Bereinigt doppelte Datensätze, die beim Abgleich zweier Geräte
    /// entstehen können.
    ///
    /// Erst zusammenführen, dann löschen: Die Kinder einer Kopie (Folgen,
    /// Fassungen, Transkripte, Segmente) wandern zur behaltenen Zeile, leere
    /// Felder werden aus der Kopie ergänzt. Gelöscht wird erst die leere Kopie.
    ///
    /// Welche Zeile bleibt, entscheiden Felder, die mit der Zeile abgeglichen
    /// werden und sich nicht mehr ändern, etwa `addedAt` oder `acquiredAt`.
    /// Die Reihenfolge der lokalen Abfrage wäre auf jedem Gerät eine andere:
    /// Jedes behielte seine eigene Zeile und löschte die des anderen, und
    /// nach dem nächsten Abgleich wären beide weg. Lässt sich keine Zeile
    /// eindeutig vorziehen, bleiben alle stehen. Die Lesefunktionen zeigen
    /// jede Kennung trotzdem nur einmal.
    ///
    /// Ist eine Kopie einer Folge gelöscht, gilt die ganze Folge als
    /// gelöscht: Was eine lebende Kopie inzwischen angesammelt hat, wird
    /// entfernt wie bei ``removeEpisode(_:)``. Wer dabei auch die
    /// Audiodateien löschen will, nimmt ``removeDuplicatesWithReport()``.
    ///
    /// Hörzustände werden nicht gelöscht, sondern beim Lesen vereinigt, siehe
    /// ``ledger()``.
    public func removeDuplicates() throws {
        _ = try removeDuplicatesWithReport()
    }

    /// Wie ``removeDuplicates()``. Der Bericht nennt die Fassungen, deren
    /// Audiodateien der Aufrufer löschen kann, weil eine Kopie der Folge
    /// gelöscht war.
    public func removeDuplicatesWithReport() throws -> RemovalReport {
        var report = RemovalReport()
        // Nach jedem Schritt speichern: Eine Abfrage sieht gelöschte Zeilen
        // sonst noch, und der nächste Schritt muss die umgehängten Kinder sehen.
        try mergeDuplicateSources()
        try modelContext.save()
        try settleEpisodeDuplicates(into: &report)
        try modelContext.save()
        try mergeDuplicateMediaVersions()
        try modelContext.save()
        try reattachOrphanedMediaVersions()
        try mergeDuplicateTranscripts()
        try modelContext.save()

        // Segmente gehören zu ihrem Transkript. Die Kennung allein reicht
        // nicht, denn sie enthält weder Revision noch Sprache.
        try removeLeafDuplicates(StoredSegment.self,
            key: { $0.identifier + "|" + ($0.transcript?.identifier ?? "") },
            order: [RowOrder.ascending { $0.text },
                    RowOrder.ascending { $0.speakerLabel ?? "" }])
        try removeLeafDuplicates(StoredInterest.self, key: \.identifier,
            order: [RowOrder.ascending { $0.createdAt }])
        try removeLeafDuplicates(StoredEvidence.self, key: \.identifier,
            order: [RowOrder.descending { $0.hasTiming ? 1 : 0 },
                    RowOrder.descending { $0.transcriptIdentifier.isEmpty ? 0 : 1 },
                    RowOrder.ascending { $0.transcriptIdentifier },
                    RowOrder.ascending { $0.quotedText },
                    RowOrder.ascending { $0.attributedSpeaker ?? "" }])
        try removeLeafDuplicates(StoredHighlight.self, key: \.identifier,
            order: [RowOrder.ascending { $0.createdAt },
                    RowOrder.ascending { $0.evidenceIdentifier }])
        try removeLeafDuplicates(StoredSmartFeed.self, key: \.identifier,
            order: [RowOrder.ascending { $0.createdAt }])
        try removeLeafDuplicates(StoredPersonalEpisode.self, key: \.identifier,
            order: [RowOrder.ascending { $0.feedIdentifier }])
        try removeLeafDuplicates(StoredKnowledgeTrail.self, key: \.identifier,
            order: [RowOrder.ascending { $0.parkedAt }])
        try removeLeafDuplicates(StoredFact.self, key: \.identifier,
            order: [RowOrder.ascending { $0.createdAt },
                    RowOrder.ascending { $0.statement }])
        try modelContext.save()
        return report
    }

    /// Gruppiert Zeilen nach Schlüssel und ordnet jede Gruppe. Zurück kommen
    /// nur Gruppen, in denen die erste Zeile eindeutig vor der zweiten steht.
    private func duplicateGroups<T: PersistentModel>(
        _ type: T.Type, key: (T) -> String, order: [RowOrder<T>.Step]
    ) throws -> [(keep: T, drop: [T])] {
        var groups: [String: [T]] = [:]
        for row in try modelContext.fetch(FetchDescriptor<T>()) {
            let value = key(row)
            guard !value.isEmpty else { continue }
            groups[value, default: []].append(row)
        }
        let ordering = RowOrder<T>(order)
        var result: [(keep: T, drop: [T])] = []
        for value in groups.keys.sorted() {
            guard let rows = groups[value], rows.count > 1 else { continue }
            let sorted = rows.sorted { ordering.compare($0, $1) == .orderedAscending }
            // Gleichstand an der Spitze: Kein Gerät könnte sicher sagen,
            // welche Zeile bleibt. Dann bleibt jede.
            guard ordering.compare(sorted[0], sorted[1]) == .orderedAscending else { continue }
            result.append((sorted[0], Array(sorted.dropFirst())))
        }
        return result
    }

    /// Für Typen ohne Kinder: Die Kopien tragen dieselben Daten wie die
    /// behaltene Zeile und können gehen.
    private func removeLeafDuplicates<T: PersistentModel>(
        _ type: T.Type, key: (T) -> String, order: [RowOrder<T>.Step]
    ) throws {
        for group in try duplicateGroups(type, key: key, order: order) {
            for row in group.drop { modelContext.delete(row) }
        }
    }

    private func mergeDuplicateSources() throws {
        let groups = try duplicateGroups(StoredSource.self, key: \.identifier, order: [
            RowOrder.ascending { $0.addedAt },
            RowOrder.ascending { $0.feedURLString ?? "" },
        ])
        guard !groups.isEmpty else { return }
        for (keep, drop) in groups {
            for copy in drop {
                for episode in Array(copy.episodes ?? []) { episode.source = keep }
                keep.author = keep.author ?? copy.author
                keep.feedURLString = keep.feedURLString ?? copy.feedURLString
                keep.websiteURLString = keep.websiteURLString ?? copy.websiteURLString
                keep.artworkURLString = keep.artworkURLString ?? copy.artworkURLString
                keep.languageCode = keep.languageCode ?? copy.languageCode
                keep.limitationReason = keep.limitationReason ?? copy.limitationReason
                keep.revisionValue = max(keep.revisionValue, copy.revisionValue)
            }
        }
        // Erst die umgehängten Kinder sichern, dann die leeren Kopien löschen.
        try modelContext.save()
        for (_, drop) in groups { for copy in drop { modelContext.delete(copy) } }
    }

    /// Folgen: gelöschte Kopien setzen sich durch, lebende werden zusammengeführt.
    private func settleEpisodeDuplicates(into report: inout RemovalReport) throws {
        var groups: [String: [StoredEpisode]] = [:]
        for row in try modelContext.fetch(FetchDescriptor<StoredEpisode>()) where !row.identifier.isEmpty {
            groups[row.identifier + "|" + (row.source?.identifier ?? ""), default: []].append(row)
        }

        // Gelöscht bleibt gelöscht. Trägt eine Kopie das Merkzeichen, gilt es
        // für alle, und was an einer lebenden Kopie hängt, geht mit.
        var purged: Set<String> = []
        for value in groups.keys.sorted() {
            guard let rows = groups[value], rows.contains(where: { $0.removedAt != nil }) else { continue }
            let hasLeftovers = rows.contains {
                $0.removedAt == nil || !($0.mediaVersions ?? []).isEmpty
                    || $0.currentMediaVersionIdentifier != nil
            }
            let identifier = rows[0].identifier
            if hasLeftovers, purged.insert(identifier).inserted {
                try purgeEpisode(identifier, keepTombstone: true, into: &report)
            }
        }

        // Lebende Kopien. Vorn steht die Kopie, an der die älteste Fassung
        // hängt. Das sieht jedes Gerät gleich, sobald die Fassungen
        // abgeglichen sind.
        let ordering = RowOrder<StoredEpisode>([
            RowOrder.ascending { ($0.mediaVersions ?? []).map(\.acquiredAt).min() ?? .distantFuture },
            RowOrder.descending { $0.currentMediaVersionIdentifier == nil ? 0 : 1 },
            RowOrder.ascending { $0.currentMediaVersionIdentifier ?? "" },
            RowOrder.ascending { $0.publishedAt ?? .distantPast },
            RowOrder.ascending { $0.audioURLString ?? "" },
        ])
        var merged: [(keep: StoredEpisode, drop: [StoredEpisode])] = []
        for value in groups.keys.sorted() {
            guard let rows = groups[value], rows.count > 1,
                  !purged.contains(rows[0].identifier),
                  !rows.contains(where: { $0.removedAt != nil }) else { continue }
            let sorted = rows.sorted { ordering.compare($0, $1) == .orderedAscending }
            guard ordering.compare(sorted[0], sorted[1]) == .orderedAscending else { continue }
            let keep = sorted[0]
            let drop = Array(sorted.dropFirst())
            for copy in drop {
                for media in Array(copy.mediaVersions ?? []) { media.episode = keep }
                keep.currentMediaVersionIdentifier = keep.currentMediaVersionIdentifier
                    ?? copy.currentMediaVersionIdentifier
                keep.summary = keep.summary ?? copy.summary
                keep.publishedAt = keep.publishedAt ?? copy.publishedAt
                if keep.declaredDurationMs == 0 { keep.declaredDurationMs = copy.declaredDurationMs }
                keep.webPageURLString = keep.webPageURLString ?? copy.webPageURLString
                keep.audioURLString = keep.audioURLString ?? copy.audioURLString
                keep.timedTranscriptURLString = keep.timedTranscriptURLString ?? copy.timedTranscriptURLString
                keep.artworkURLString = keep.artworkURLString ?? copy.artworkURLString
                keep.chaptersData = keep.chaptersData ?? copy.chaptersData
                keep.chaptersURLString = keep.chaptersURLString ?? copy.chaptersURLString
                keep.shownotesHTML = keep.shownotesHTML ?? copy.shownotesHTML
                keep.revisionValue = max(keep.revisionValue, copy.revisionValue)
            }
            merged.append((keep, drop))
        }
        guard !merged.isEmpty else { return }
        try modelContext.save()
        for (_, drop) in merged { for copy in drop { modelContext.delete(copy) } }
    }

    private func mergeDuplicateMediaVersions() throws {
        let groups = try duplicateGroups(StoredMediaVersion.self, key: \.identifier, order: [
            RowOrder.ascending { $0.acquiredAt },
            RowOrder.ascending { $0.remoteURLString ?? "" },
        ])
        guard !groups.isEmpty else { return }
        for (keep, drop) in groups {
            for copy in drop {
                for transcript in Array(copy.transcripts ?? []) { transcript.mediaVersion = keep }
                keep.episode = keep.episode ?? copy.episode
                keep.remoteURLString = keep.remoteURLString ?? copy.remoteURLString
                keep.localRelativePath = keep.localRelativePath ?? copy.localRelativePath
                keep.contentHash = keep.contentHash ?? copy.contentHash
                keep.mimeType = keep.mimeType ?? copy.mimeType
                if keep.byteCount == 0 { keep.byteCount = copy.byteCount }
                if keep.durationMs == 0 { keep.durationMs = copy.durationMs }
            }
        }
        try modelContext.save()
        for (_, drop) in groups { for copy in drop { modelContext.delete(copy) } }
    }

    /// Hängt Fassungen ohne Folge wieder an. Das passiert, wenn ein anderes
    /// Gerät eine doppelte Folge gelöscht hat, bevor die umgehängten Fassungen
    /// hier angekommen sind.
    private func reattachOrphanedMediaVersions() throws {
        let orphans = try modelContext.fetch(FetchDescriptor<StoredMediaVersion>(
            predicate: #Predicate { $0.episode == nil }))
        guard !orphans.isEmpty else { return }
        var byMediaKey: [String: StoredEpisode] = [:]
        let live = try modelContext.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.removedAt == nil },
            sortBy: [SortDescriptor(\.identifier)]))
        for episode in live {
            if let current = episode.currentMediaVersionIdentifier, byMediaKey[current] == nil {
                byMediaKey[current] = episode
            }
            if let audio = episode.audioURLString {
                let key = MediaVersionID(stable: audio).rawValue
                if byMediaKey[key] == nil { byMediaKey[key] = episode }
            }
        }
        for media in orphans {
            if let episode = byMediaKey[media.identifier] { media.episode = episode }
        }
        try modelContext.save()
    }

    private func mergeDuplicateTranscripts() throws {
        let groups = try duplicateGroups(StoredTranscript.self, key: \.identifier, order: [
            RowOrder.ascending { $0.createdAt },
            RowOrder.descending { $0.revisionValue },
        ])
        guard !groups.isEmpty else { return }
        for (keep, drop) in groups {
            var present = Set((keep.segments ?? []).map(\.identifier))
            for copy in drop {
                // Nur Segmente, die der behaltenen Zeile fehlen. Die übrigen
                // sind Kopien von Segmenten, die sie schon hat.
                for segment in Array(copy.segments ?? []) where present.insert(segment.identifier).inserted {
                    segment.transcript = keep
                }
                keep.mediaVersion = keep.mediaVersion ?? copy.mediaVersion
                keep.untimedText = keep.untimedText ?? copy.untimedText
                keep.analyzedRangesFlat = StoredTranscript.flat(from: IntervalSet(
                    StoredTranscript.ranges(from: keep.analyzedRangesFlat)
                        + StoredTranscript.ranges(from: copy.analyzedRangesFlat)))
            }
        }
        try modelContext.save()
        for (_, drop) in groups { for copy in drop { modelContext.delete(copy) } }
    }

    // MARK: - Quellen

    public func upsert(source: Source) throws {
        let identifier = source.id.rawValue
        var rows = try modelContext.fetch(
            FetchDescriptor<StoredSource>(predicate: #Predicate { $0.identifier == identifier })
        )
        if rows.isEmpty {
            let fresh = StoredSource(identifier: identifier, kind: source.kind, title: source.title)
            modelContext.insert(fresh)
            rows = [fresh]
        }
        // Alle Kopien gleich halten, solange das Bereinigen keine vorziehen kann.
        for stored in rows {
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
        }
        try modelContext.save()
    }

    public func sources() throws -> [Source] {
        try modelContext.fetch(
            FetchDescriptor<StoredSource>(sortBy: [SortDescriptor(\.title), SortDescriptor(\.addedAt)])
        ).uniqued(by: \.identifier).map(\.snapshot)
    }

    // MARK: - Folgen

    /// Legt Folgen an oder aktualisiert sie.
    ///
    /// Die Deduplizierung läuft über die stabile Kennung aus der Feed-GUID.
    /// Ein zweites Einlesen desselben Feeds darf keine zweite Folge erzeugen —
    /// sonst wächst die Mediathek bei jedem Refresh.
    public func upsert(episodes: [Episode], forSource sourceID: SourceID) throws -> Int {
        let identifier = sourceID.rawValue
        // Bei doppelten Quellzeilen dieselbe wie beim Bereinigen: die älteste.
        guard let source = try modelContext.fetch(
            FetchDescriptor<StoredSource>(
                predicate: #Predicate { $0.identifier == identifier },
                sortBy: [SortDescriptor(\.addedAt)])
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
            )
            // Gelöscht bleibt gelöscht, auch wenn der Feed die Folge weiter
            // führt. Das gilt, sobald irgendeine Kopie das Merkzeichen trägt,
            // nicht nur die, die die Abfrage zufällig zuerst liefert.
            if existing.contains(where: { $0.removedAt != nil }) { continue }

            var rows = existing
            if rows.isEmpty {
                let fresh = StoredEpisode(identifier: episodeIdentifier, title: episode.title)
                fresh.source = source
                modelContext.insert(fresh)
                rows = [fresh]
                inserted += 1
            }
            // Alle Kopien gleich halten, solange das Bereinigen keine vorziehen kann.
            for stored in rows {
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

        // Kennungen, die irgendwo als gelöscht markiert sind. Eine lebende
        // Kopie derselben Folge, etwa vom anderen Gerät, darf sie nicht
        // zurückbringen.
        var removedDescriptor = FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.source?.identifier == identifier && $0.removedAt != nil })
        removedDescriptor.propertiesToFetch = [\.identifier]
        let removed = Set(try modelContext.fetch(removedDescriptor).map(\.identifier))

        var descriptor = FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.source?.identifier == identifier && $0.removedAt == nil },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse), SortDescriptor(\.identifier)]
        )
        descriptor.fetchLimit = limit + removed.count
        let rows = try modelContext.fetch(descriptor)
            .filter { !removed.contains($0.identifier) }
            .uniqued(by: \.identifier, preferring: { $0.currentMediaVersionIdentifier != nil })
        return rows.prefix(limit).map(\.snapshot)
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
            // Gibt es nach einem Abgleich mehrere Zeilen, genügt eine davon:
            // ``ledger()`` vereinigt beim Lesen alle.
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
    ///
    /// Mehrere Zeilen für dieselbe Fassung, etwa von zwei Geräten vor dem
    /// Abgleich, werden vereinigt. Bisher gewann die zuletzt gelesene, und
    /// was das andere Gerät gehört hatte, galt wieder als ungehört.
    public func ledger() throws -> ListeningLedger {
        let states = try modelContext.fetch(FetchDescriptor<StoredListeningState>())
        var result: [MediaVersionID: MediaListeningState] = [:]
        for stored in states where !stored.mediaVersionIdentifier.isEmpty {
            let snapshot = stored.snapshot
            result[snapshot.mediaVersionID] = result[snapshot.mediaVersionID]
                .map { $0.merged(with: snapshot) } ?? snapshot
        }
        return ListeningLedger(states: result)
    }

    // MARK: - Interessen

    public func interestProfile(learningEnabled: Bool) throws -> InterestProfile {
        let interests = try modelContext.fetch(
            FetchDescriptor<StoredInterest>(sortBy: [SortDescriptor(\.createdAt)])
        ).uniqued(by: \.identifier).map(\.snapshot)
        return InterestProfile(interests: interests, learningEnabled: learningEnabled)
    }

    public func upsert(interest: Interest) throws {
        let identifier = interest.id.rawValue
        var rows = try modelContext.fetch(
            FetchDescriptor<StoredInterest>(predicate: #Predicate { $0.identifier == identifier })
        )
        if rows.isEmpty {
            let fresh = StoredInterest(identifier: identifier, label: interest.label)
            modelContext.insert(fresh)
            rows = [fresh]
        }
        for stored in rows {
            stored.label = interest.label
            stored.kindRaw = interest.kind.rawValue
            stored.originRaw = interest.origin.rawValue
            stored.keywords = interest.keywords
            stored.expiresAt = interest.expiresAt
        }
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
        let candidates = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(
                predicate: #Predicate { $0.identifier == episodeKey }
            )
        )
        // Lieber eine lebende Kopie. Hängt die Fassung doch an einer
        // gelöschten, räumt das nächste Bereinigen sie wieder ab.
        let episode = candidates.first { $0.removedAt == nil } ?? candidates.first
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
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).map(\.snapshot)
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
        // Jede Folge einmal, auch wenn sie nach einem Abgleich doppelt vorliegt.
        var episodeKeys: [String] = []
        for source in sources {
            for episode in source.episodes ?? [] where !episodeKeys.contains(episode.identifier) {
                episodeKeys.append(episode.identifier)
            }
        }
        for episodeKey in episodeKeys {
            try purgeEpisode(episodeKey, keepTombstone: false, into: &report)
        }
        for source in sources { modelContext.delete(source) }
        try modelContext.save()
        return report
    }

    private func purgeEpisode(_ key: String, keepTombstone: Bool, into report: inout RemovalReport) throws {
        let episodes = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.identifier == key }))
        // Ein vorhandenes Löschdatum bleibt, und alle Kopien tragen dasselbe.
        let removedAt = episodes.compactMap(\.removedAt).min() ?? Date()
        var mediaKeys: Set<String> = []
        for episode in episodes {
            // Die Fassungen selbst werden weiter unten über ihre Kennung
            // gelöscht. Die Beziehung löscht nicht mehr mit, siehe `Models.swift`.
            for media in episode.mediaVersions ?? [] { mediaKeys.insert(media.identifier) }
            if let current = episode.currentMediaVersionIdentifier { mediaKeys.insert(current) }
            if let audio = episode.audioURLString {
                mediaKeys.insert(MediaVersionID(stable: audio).rawValue)
            }
            if keepTombstone {
                episode.removedAt = removedAt
                episode.currentMediaVersionIdentifier = nil
            } else {
                modelContext.delete(episode)
            }
        }
        if !episodes.isEmpty { report.episodeIDs.append(EpisodeID(rawValue: key)) }

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

    /// Nur für Tests: eine zweite Zeile derselben Quelle, wie sie der Abgleich
    /// von einem anderen Gerät bringt.
    func insertSourceCopyForTesting(_ source: Source, addedAt: Date) throws {
        let row = StoredSource(identifier: source.id.rawValue, kind: source.kind, title: source.title)
        row.feedURLString = source.feedURL?.absoluteString
        row.addedAt = addedAt
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Nur für Tests: eine Zeile einer Folge ohne Prüfung auf Doppelte, auf
    /// Wunsch mit Fassung, Transkript und Segmenten, so wie sie das andere
    /// Gerät angelegt hat. `underSourceAddedAt` wählt die Quellzeile.
    func insertEpisodeCopyForTesting(
        _ episode: Episode,
        underSourceAddedAt sourceAddedAt: Date? = nil,
        media: MediaVersion? = nil,
        acquiredAt: Date? = nil,
        transcript: Transcript? = nil,
        removedAt: Date? = nil
    ) throws {
        let key = episode.sourceID.rawValue
        let sources = try modelContext.fetch(FetchDescriptor<StoredSource>(
            predicate: #Predicate { $0.identifier == key }))
        let row = StoredEpisode(identifier: episode.id.rawValue, title: episode.title)
        row.audioURLString = episode.audioURL?.absoluteString
        row.publishedAt = episode.publishedAt
        row.removedAt = removedAt
        row.source = sources.first { $0.addedAt == sourceAddedAt } ?? sources.first
        modelContext.insert(row)
        if let media {
            let storedMedia = StoredMediaVersion(identifier: media.id.rawValue)
            storedMedia.remoteURLString = media.remoteURL?.absoluteString
            if let acquiredAt { storedMedia.acquiredAt = acquiredAt }
            storedMedia.episode = row
            modelContext.insert(storedMedia)
            row.currentMediaVersionIdentifier = media.id.rawValue
            if let transcript {
                let storedTranscript = StoredTranscript(identifier: transcript.id.rawValue)
                storedTranscript.revisionValue = transcript.revision.value
                storedTranscript.createdAt = transcript.createdAt
                storedTranscript.analyzedRangesFlat = StoredTranscript.flat(from: transcript.analyzedRanges)
                storedTranscript.mediaVersion = storedMedia
                modelContext.insert(storedTranscript)
                for segment in transcript.segments {
                    let piece = StoredSegment(
                        identifier: segment.id.rawValue,
                        startMs: Int(segment.range.start.milliseconds),
                        endMs: Int(segment.range.end.milliseconds),
                        text: segment.text)
                    piece.transcript = storedTranscript
                    modelContext.insert(piece)
                }
            }
        }
        try modelContext.save()
    }

    /// Nur für Tests: eine weitere Zeile Hörzustand für dieselbe Fassung.
    func insertListeningStateCopyForTesting(_ state: MediaListeningState) throws {
        let row = StoredListeningState(mediaVersionIdentifier: state.mediaVersionID.rawValue)
        row.apply(state)
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Nur für Tests: wie viele Zeilen eines Typs gespeichert sind.
    func rowCountForTesting<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<T>())
    }

    // MARK: - Transkript und Fakten je Folge

    /// Das Transkript einer Folge.
    ///
    /// Zuerst das der aktuellen Fassung, denn auf sie beziehen sich Belege
    /// und Fakten. Fehlt es, das jüngste über alle Fassungen. Bisher kam das
    /// erste in der Reihenfolge der Kennungen, und die ist ein Hashwert: Nach
    /// einem Wechsel der Audioadresse konnte das Transkript der alten Fassung
    /// erscheinen.
    public func transcript(forEpisode episodeID: EpisodeID) throws -> Transcript? {
        let key = episodeID.rawValue
        let rows = try modelContext.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.identifier == key }))
        for current in Set(rows.compactMap(\.currentMediaVersionIdentifier)).sorted() {
            if let transcript = try transcript(forMedia: MediaVersionID(rawValue: current)),
               !transcript.segments.isEmpty {
                return transcript
            }
        }
        var newest: Transcript?
        for id in try mediaVersionIDs(forEpisode: episodeID) {
            guard let transcript = try transcript(forMedia: id), !transcript.segments.isEmpty else { continue }
            if let best = newest,
               (best.createdAt, best.revision.value) >= (transcript.createdAt, transcript.revision.value) {
                continue
            }
            newest = transcript
        }
        return newest
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
            sortBy: [SortDescriptor(\.startMs)])).uniqued(by: \.identifier).map(\.snapshot)
    }

    /// Alle Fakten, etwa für den Chat über alle Folgen.
    public func allFacts(limit: Int = 2_000) throws -> [EpisodeFact] {
        var descriptor = FetchDescriptor<StoredFact>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).map(\.snapshot)
    }

    /// Belege aller Quellen, die für einen Themenfeed infrage kommen.
    public func evidenceForAnalyzedEpisodes(limit: Int = 500) throws -> [Evidence] {
        var descriptor = FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.hasTiming == true }
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).map(\.snapshot)
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
        ).uniqued(by: \.identifier, preferring: { $0.currentMediaVersionIdentifier != nil })
        .map(\.snapshot)
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
        var existing: [String: [StoredSmartFeed]] = [:]
        // Ein Durchlauf: behalten oder löschen. Ein zweiter `fetch` nach
        // dem Löschen sähe die gelöschten Zeilen noch.
        for row in try modelContext.fetch(FetchDescriptor<StoredSmartFeed>()) {
            if keep.contains(row.identifier) {
                // Alle Kopien, nicht nur die letzte: Doppelte, die das
                // Bereinigen stehen lässt, sollen gleich bleiben.
                existing[row.identifier, default: []].append(row)
            } else {
                // Was der Nutzer gelöscht hat, verschwindet auch hier.
                modelContext.delete(row)
            }
        }

        for feed in smartFeeds {
            let payload = try Self.encoder.encode(feed)
            if let rows = existing[feed.id.rawValue] {
                for row in rows {
                    row.title = feed.title
                    row.payload = payload
                }
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
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).compactMap {
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
        var existing: [String: [StoredPersonalEpisode]] = [:]
        for row in stored {
            if keep.contains(row.identifier) {
                existing[row.identifier, default: []].append(row)
            } else {
                modelContext.delete(row)
            }
        }
        for episode in editions {
            let payload = try Self.encoder.encode(episode)
            if let rows = existing[episode.id.rawValue] {
                for row in rows {
                    row.publishedAt = episode.publishedAt
                    row.payload = payload
                }
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
        for row in try modelContext.fetch(descriptor).uniqued(by: \.identifier) {
            guard let episode = try? Self.decoder.decode(
                PersonalEpisode.self, from: row.payload) else { continue }
            result[SmartFeedID(rawValue: row.feedIdentifier), default: []].append(episode)
        }
        return result
    }

    public func save(trails: [KnowledgeTrail]) throws {
        let keep = Set(trails.map(\.id.rawValue))
        let stored = try modelContext.fetch(FetchDescriptor<StoredKnowledgeTrail>())
        var existing: [String: [StoredKnowledgeTrail]] = [:]
        for row in stored {
            if keep.contains(row.identifier) {
                existing[row.identifier, default: []].append(row)
            } else {
                modelContext.delete(row)
            }
        }
        for trail in trails {
            let payload = try Self.encoder.encode(trail)
            if let rows = existing[trail.id.rawValue] {
                for row in rows {
                    row.question = trail.question
                    row.payload = payload
                }
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
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).compactMap {
            try? Self.decoder.decode(KnowledgeTrail.self, from: $0.payload)
        }
    }

    public func save(highlights: [Highlight]) throws {
        let keep = Set(highlights.map(\.id.rawValue))
        let stored = try modelContext.fetch(FetchDescriptor<StoredHighlight>())
        var existing: [String: [StoredHighlight]] = [:]
        for row in stored {
            if keep.contains(row.identifier) {
                existing[row.identifier, default: []].append(row)
            } else {
                modelContext.delete(row)
            }
        }
        for highlight in highlights {
            let payload = try Self.encoder.encode(highlight)
            if let rows = existing[highlight.id.rawValue] {
                for row in rows {
                    row.note = highlight.note
                    row.payload = payload
                }
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
        return try modelContext.fetch(descriptor).uniqued(by: \.identifier).compactMap { row in
            guard let payload = row.payload else { return nil }
            return try? Self.decoder.decode(Highlight.self, from: payload)
        }
    }
}

/// Reihenfolge, nach der das Bereinigen die Zeile wählt, die bleibt.
///
/// Gebaut nur aus Feldern, die mit der Zeile abgeglichen werden. Dann ordnet
/// jedes Gerät dieselben Zeilen gleich und behält dieselbe.
struct RowOrder<Row> {
    typealias Step = (Row, Row) -> ComparisonResult

    let steps: [Step]

    init(_ steps: [Step]) { self.steps = steps }

    func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult {
        for step in steps {
            let result = step(lhs, rhs)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    static func ascending<Value: Comparable>(_ value: @escaping (Row) -> Value) -> Step {
        { lhs, rhs in
            let a = value(lhs), b = value(rhs)
            if a < b { return .orderedAscending }
            if b < a { return .orderedDescending }
            return .orderedSame
        }
    }

    static func descending<Value: Comparable>(_ value: @escaping (Row) -> Value) -> Step {
        let forward = ascending(value)
        return { lhs, rhs in forward(rhs, lhs) }
    }
}

extension Array {
    /// Jede Kennung einmal, in der bisherigen Reihenfolge. Liegt eine
    /// Kennung mehrfach vor, gewinnt die erste Zeile, die `preferring`
    /// erfüllt, sonst die erste überhaupt.
    func uniqued(
        by key: (Element) -> String,
        preferring better: (Element) -> Bool = { _ in false }
    ) -> [Element] {
        var position: [String: Int] = [:]
        var result: [Element] = []
        for element in self {
            let value = key(element)
            if let index = position[value] {
                if !better(result[index]) && better(element) { result[index] = element }
            } else {
                position[value] = result.count
                result.append(element)
            }
        }
        return result
    }
}
#endif
