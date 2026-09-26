//
//  WhatsNewWidget.swift
//  PodcastAIWidget (iOS und macOS)
//
//  Das Widget „Was ist neu“. Es liest nur den Schnappschuss, den die App
//  in den Ordner der App Group schreibt: neue Aussagen je gefolgtem Tag,
//  die neueste Ausgabe der Themen-Updates und angesagte Tags. Keine
//  Datenbank, kein Modell, kein Netz.
//
//  Ein Tipp öffnet die App über `podcastai://topicupdates`, eine Tag-Zeile
//  im mittleren Widget über `podcastai://tag/<Kennung>`. Abgespielt wird
//  dabei nichts.
//

import SwiftUI
import WidgetKit
import PodcastAIWidgetData

@main
struct PodcastAIWidgets: WidgetBundle {
    var body: some Widget {
        WhatsNewWidget()
    }
}

struct WhatsNewWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.whatsNew, provider: WhatsNewProvider()) { entry in
            WhatsNewWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Was ist neu")
        .description("Neue Aussagen zu deinen Tags und die neueste Ausgabe deiner Themen-Updates.")
        .supportedFamilies(Self.families)
    }

    /// Klein und mittel überall, dazu der Sperrbildschirm auf iPhone und iPad.
    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct WhatsNewEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WhatsNewProvider: TimelineProvider {

    func placeholder(in context: Context) -> WhatsNewEntry {
        WhatsNewEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (WhatsNewEntry) -> Void) {
        completion(currentEntry(forGallery: context.isPreview))
    }

    /// Ein Eintrag ohne Ablauf: Neu geladen wird, wenn die App einen neuen
    /// Stand schreibt. Von selbst ändert sich nichts.
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<WhatsNewEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry(forGallery: false)], policy: .never))
    }

    /// In der Widget-Galerie zeigt ein leerer Stand ein Beispiel, damit man
    /// sieht, was das Widget kann.
    private func currentEntry(forGallery: Bool) -> WhatsNewEntry {
        let stored = WidgetSnapshotStore.appGroup()?.read()
        if forGallery, stored?.isEmpty ?? true {
            return WhatsNewEntry(date: Date(), snapshot: .sample)
        }
        return WhatsNewEntry(date: Date(), snapshot: stored ?? WidgetSnapshot(generatedAt: Date()))
    }
}

extension WidgetSnapshot {

    /// Beispiel für Galerie und Platzhalter.
    static var sample: WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            newStatements: [
                TagCount(tagID: "sample-1",
                         label: String(localized: "Datenschutz", comment: "Beispiel-Tag in der Widget-Galerie"), count: 12),
                TagCount(tagID: "sample-2",
                         label: String(localized: "Sprachmodelle", comment: "Beispiel-Tag in der Widget-Galerie"), count: 7),
                TagCount(tagID: "sample-3",
                         label: String(localized: "Energie", comment: "Beispiel-Tag in der Widget-Galerie"), count: 3),
            ],
            latestEdition: Edition(
                id: "sample",
                title: String(localized: "Datenschutz und USA, Teil 1", comment: "Beispiel-Ausgabe in der Widget-Galerie"),
                feedTitle: String(localized: "Datenschutz und USA", comment: "Beispiel-Update in der Widget-Galerie"),
                publishedAt: Date()))
    }
}
