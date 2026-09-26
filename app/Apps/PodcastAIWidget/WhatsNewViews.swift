//
//  WhatsNewViews.swift
//  PodcastAIWidget (iOS und macOS)
//
//  Die Ansichten des Widgets „Was ist neu“, je Größe eine. Klein: bis zu
//  drei Tags mit ihren neuen Aussagen und darunter die neueste Ausgabe.
//  Mittel: links die Tags, jede Zeile führt auf die Seite ihres Tags,
//  rechts die neueste Ausgabe und, wenn die App sie zählt, angesagte Tags.
//  Auf dem Sperrbildschirm eine kurze Fassung davon.
//

import SwiftUI
import WidgetKit
import PodcastAIWidgetData

struct WhatsNewWidgetView: View {

    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            WhatsNewRectangularView(snapshot: snapshot)
        case .accessoryInline:
            WhatsNewInlineView(snapshot: snapshot)
        #endif
        case .systemMedium:
            WhatsNewMediumView(snapshot: snapshot)
        default:
            WhatsNewSmallView(snapshot: snapshot)
        }
    }
}

// MARK: - Klein

struct WhatsNewSmallView: View {

    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WhatsNewHeading()
            if snapshot.newStatements.isEmpty {
                NothingNewText()
            } else {
                ForEach(snapshot.newStatements) { TagCountRow(tag: $0) }
            }
            Spacer(minLength: 0)
            if let edition = snapshot.latestEdition {
                Text(verbatim: edition.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel(Text("Neueste Ausgabe: \(edition.title)"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Das kleine Widget kennt nur ein Ziel für den ganzen Tipp.
        .widgetURL(WidgetLink.topicUpdates.url)
    }
}

// MARK: - Mittel

struct WhatsNewMediumView: View {

    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                WhatsNewHeading()
                if snapshot.newStatements.isEmpty {
                    NothingNewText()
                } else {
                    ForEach(snapshot.newStatements) { tag in
                        Link(destination: WidgetLink.tag(tag.tagID).url) { TagCountRow(tag: tag) }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Neueste Ausgabe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let edition = snapshot.latestEdition {
                    Text(verbatim: edition.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(verbatim: edition.feedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Noch keine Ausgabe")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !snapshot.trendingTags.isEmpty {
                    Text("Angesagt")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: snapshot.trendingTags.map(\.label).formatted(.list(type: .and)))
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetURL(WidgetLink.topicUpdates.url)
    }
}

// MARK: - Sperrbildschirm

#if os(iOS)
struct WhatsNewRectangularView: View {

    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Was ist neu")
                .font(.headline)
                .widgetAccentable()
            if snapshot.newStatements.isEmpty {
                if let edition = snapshot.latestEdition {
                    Text(verbatim: edition.title)
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    NothingNewText()
                }
            } else {
                ForEach(snapshot.newStatements.prefix(2)) { TagCountRow(tag: $0, font: .caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetLink.topicUpdates.url)
    }
}

struct WhatsNewInlineView: View {

    let snapshot: WidgetSnapshot

    var body: some View {
        Label {
            if let top = snapshot.newStatements.first {
                Text("\(top.label): \(top.count) neu")
            } else if let edition = snapshot.latestEdition {
                Text(verbatim: edition.title)
            } else {
                Text("Nichts Neues zu deinen Tags")
            }
        } icon: {
            Image(systemName: "waveform.circle")
        }
        .widgetURL(WidgetLink.topicUpdates.url)
    }
}
#endif

// MARK: - Bausteine

/// Überschrift mit demselben Symbol wie der Tab „Themen-Updates“.
private struct WhatsNewHeading: View {
    var body: some View {
        Label("Was ist neu", systemImage: "waveform.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NothingNewText: View {
    var body: some View {
        Text("Nichts Neues zu deinen Tags")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// Ein Tag und die Zahl seiner neuen Aussagen.
private struct TagCountRow: View {

    let tag: WidgetSnapshot.TagCount
    var font: Font = .subheadline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: tag.label)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(tag.count, format: .number)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.tint)
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tag.label))
        .accessibilityValue(Text("\(tag.count) neue Aussagen"))
    }
}
