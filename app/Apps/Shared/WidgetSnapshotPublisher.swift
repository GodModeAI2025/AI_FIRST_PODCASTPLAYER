//
//  WidgetSnapshotPublisher.swift
//  PodcastAI
//
//  Bringt „Was ist neu“ ins Widget: neue Aussagen je gefolgtem Tag, die
//  neueste Ausgabe der Themen-Updates und, sobald es sie gibt, angesagte
//  Tags. Die App schreibt dafür einen kleinen Schnappschuss in den Ordner
//  der App Group (`WidgetSnapshotStore`) und lädt danach das Widget neu.
//
//  Im Schnappschuss stehen nur Zahlen, Titel und Kennungen. Kein Satz aus
//  einem Transkript, keine Aussage.
//
//  Zwei Stellen im `AppModel` rufen hierher: das Ende des Rechnens der
//  Zahlen (`computeSmartFeedStatistics`) und jede Änderung an `editions`,
//  auch durch „Folge löschen“, „Abbestellen“ oder das Löschen eines
//  Updates. Wie oft wirklich geschrieben wird, regelt `WidgetSnapshotWriter`.
//

import Foundation
import PodcastAIKit
import WidgetKit
#if os(iOS)
import UIKit
#endif

@MainActor
final class WidgetSnapshotPublisher {

    static let shared = WidgetSnapshotPublisher()

    /// Erst wahr, wenn die Zahlen einmal gerechnet sind. Vorher kennt die
    /// App die neuen Aussagen noch nicht, und ein früher Stand ohne sie
    /// hielte die richtigen Zahlen bis zu fünf Minuten zurück.
    fileprivate var hasStatistics = false

    /// Ein Stand auf dem Weg zum Schreiber.
    private struct Submission: Sendable {
        let snapshot: WidgetSnapshot
        /// `false` im Hintergrund: dort wird auch Zuwachs sofort geschrieben.
        let deferGrowth: Bool
    }

    private let writer: WidgetSnapshotWriter?
    /// Eine Schlange für die Stände, damit sie in ihrer Reihenfolge beim
    /// Schreiber ankommen. Wartet einer, zählt nur der neueste.
    private let submissions: AsyncStream<Submission>.Continuation?
    /// Der zuletzt weitergegebene Stand. Er kann noch in der Schlange
    /// stecken, wenn die App in den Hintergrund geht.
    private var latest: WidgetSnapshot?
    private var backgroundObserver: (any NSObjectProtocol)?
    #if os(iOS)
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    private init() {
        // Ohne App Group, etwa in einem Build ohne Signatur, gibt es kein Widget.
        guard let store = WidgetSnapshotStore.appGroup() else {
            writer = nil
            submissions = nil
            return
        }
        let writer = WidgetSnapshotWriter(store: store, didWrite: {
            await MainActor.run { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.whatsNew) }
        })
        self.writer = writer
        let (stream, continuation) = AsyncStream.makeStream(
            of: Submission.self, bufferingPolicy: .bufferingNewest(1))
        submissions = continuation
        Task.detached(priority: .utility) {
            for await submission in stream {
                await writer.submit(submission.snapshot, deferGrowth: submission.deferGrowth)
            }
        }
        #if os(iOS)
        // Was noch auf seine fünf Minuten wartet, kommt vor dem Anhalten ins Widget.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushBeforeSuspension() }
        }
        #endif
    }

    /// - Parameter deferGrowth: `false`, wenn die App im Hintergrund ist.
    func publish(_ snapshot: WidgetSnapshot, deferGrowth: Bool) {
        guard let submissions else { return }
        latest = snapshot
        submissions.yield(Submission(snapshot: snapshot, deferGrowth: deferGrowth))
    }

    #if os(iOS)
    /// Schreibt den neuesten Stand, bevor das System die App anhält. Mit
    /// etwas Hintergrundzeit, damit das Schreiben nicht mittendrin stehen
    /// bleibt. Über den Schreiber, damit er weiß, was in der Datei steht.
    private func flushBeforeSuspension() {
        guard let writer, let latest else { return }
        let holdsTime = backgroundTask == .invalid
        if holdsTime {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Widget") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        Task { [weak self] in
            await writer.flush(latest: latest)
            if holdsTime { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

extension AppModel {

    /// Gibt den aktuellen Stand ans Widget weiter.
    ///
    /// - Parameter afterStatistics: `true`, wenn die Zahlen der
    ///   Themen-Updates gerade neu gerechnet sind.
    func publishWidgetSnapshot(afterStatistics: Bool = false) {
        // UI-Tests und ein Speicher nur im Arbeitsspeicher überschreiben
        // nicht, was das Widget aus der echten Bibliothek zeigt.
        guard !store.isInMemory else { return }
        let publisher = WidgetSnapshotPublisher.shared
        if afterStatistics { publisher.hasStatistics = true }
        guard publisher.hasStatistics else { return }
        // Im Hintergrund kann das System die App jederzeit anhalten. Ein
        // Stand, der dort auf seine fünf Minuten wartete, käme nie an.
        publisher.publish(widgetSnapshot(), deferGrowth: appInForeground)
    }

    /// Der Stand fürs Widget: Zahlen aus dem Kopf der Themen-Updates, nur
    /// für Tags, denen jemand folgt, und der Titel der neuesten Ausgabe.
    func widgetSnapshot(generatedAt: Date = Date()) -> WidgetSnapshot {
        let feedTitles = Dictionary(smartFeeds.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let editionSummaries = editions.values.joined().compactMap { edition -> WidgetSnapshot.Edition? in
            guard let feedTitle = feedTitles[edition.feedID] else { return nil }
            return WidgetSnapshot.Edition(id: edition.id.rawValue, title: edition.title,
                                          feedTitle: feedTitle, publishedAt: edition.publishedAt)
        }
        return WidgetSnapshot.whatsNew(
            newStatements: topicUpdatesHeader.map {
                WidgetSnapshot.TagCount(tagID: $0.tagID.rawValue, label: $0.label, count: $0.count)
            },
            // Dieselbe Auswahl wie `followedTagIDs` für die Themen-Updates.
            followedTagIDs: Set(profile.publicationDrivers().map(\.id.rawValue)),
            editions: editionSummaries,
            trendingTags: widgetTrendingTags,
            generatedAt: generatedAt)
    }

    /// Angesagte Tags fürs Widget. Leer, bis die App Trends zählt; dann
    /// liefert die Trendzählung sie hier, das Widget zeigt sie von selbst.
    var widgetTrendingTags: [WidgetSnapshot.TagCount] { [] }
}
