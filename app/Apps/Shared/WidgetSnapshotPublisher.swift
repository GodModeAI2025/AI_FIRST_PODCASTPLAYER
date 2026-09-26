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

    /// Eine Schlange für die Stände, damit sie in ihrer Reihenfolge beim
    /// Schreiber ankommen. Wartet einer, zählt nur der neueste.
    private let submissions: AsyncStream<WidgetSnapshot>.Continuation?
    private var backgroundObserver: (any NSObjectProtocol)?

    private init() {
        // Ohne App Group, etwa in einem Build ohne Signatur, gibt es kein Widget.
        guard let store = WidgetSnapshotStore.appGroup() else {
            submissions = nil
            return
        }
        let writer = WidgetSnapshotWriter(store: store, didWrite: {
            await MainActor.run { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.whatsNew) }
        })
        let (stream, continuation) = AsyncStream.makeStream(
            of: WidgetSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        submissions = continuation
        Task.detached(priority: .utility) {
            for await snapshot in stream { await writer.submit(snapshot) }
        }
        #if os(iOS)
        // Was noch auf seine fünf Minuten wartet, kommt vor dem Anhalten ins Widget.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in
            Task { await writer.flush() }
        }
        #endif
    }

    func publish(_ snapshot: WidgetSnapshot) {
        submissions?.yield(snapshot)
    }
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
        publisher.publish(widgetSnapshot())
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
