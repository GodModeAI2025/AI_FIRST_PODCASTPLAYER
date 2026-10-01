//
//  MacTagsPage.swift
//  PodcastAI
//
//  „Meine Tags“ auf dem Mac: Tags als umbrechende Kapseln statt einer
//  flachen Liste. Gefolgte Tags tragen die Akzentfarbe und ein Häkchen,
//  neutrale bleiben grau. Die Zahl der Kapitel steht klein in der Kapsel,
//  Minus oder Plus am Ende ändert das Folgen. Nur macOS, die iPhone-Liste
//  bleibt, wie sie ist.
//
//  Nichts hier spielt Ton. Ein Klick öffnet die Seite des Tags.
//

#if os(macOS)
import SwiftUI
import PodcastAIKit

struct MacTagsPage: View {

    let trending: [TrendingTag]
    let followed: [Tag]
    let neutral: [Tag]
    let isSearching: Bool
    let counts: [InterestID: Int]

    /// Höchstbreite des Inhalts, links ausgerichtet wie die anderen Mac-Seiten.
    private static let contentWidth: CGFloat = 900

    var body: some View {
        ScrollView {
            if trending.isEmpty && followed.isEmpty && neutral.isEmpty && isSearching {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                VStack(alignment: .leading, spacing: Design.Spacing.large) {
                    if !trending.isEmpty {
                        group(title: "Angesagt", count: trending.count, note: Text(TrendText.footer())) {
                            MacTrendingList(entries: trending)
                        }
                    }
                    group(title: "Du folgst", count: followed.count,
                          note: Text("Gefolgte Tags füllen „Für dich“ und die Themen-Updates. Minus beendet das Folgen, das Tag bleibt.")) {
                        if followed.isEmpty {
                            Text(isSearching
                                 ? "Kein gefolgtes Tag passt zur Suche."
                                 : "Du folgst noch keinem Tag. Tippe bei einem Tag auf Plus.")
                                .foregroundStyle(.secondary)
                        } else {
                            cloud(followed)
                        }
                    }
                    if !neutral.isEmpty {
                        group(title: "Weitere Tags aus deinen Folgen", count: neutral.count,
                              note: Text("Plus nimmt ein Tag in „Für dich“ und die Themen-Updates auf.")) {
                            cloud(neutral)
                        }
                    }
                }
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Design.Spacing.section)
            }
        }
        .contentMargins(.horizontal, Design.Spacing.large, for: .scrollContent)
    }

    private func cloud(_ tags: [Tag]) -> some View {
        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.small) {
            ForEach(tags) { tag in
                MacTagPill(tag: tag, count: counts[tag.id] ?? 0)
            }
        }
    }

    private func group<Content: View>(
        title: LocalizedStringKey, count: Int, note: Text,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(count, format: .number)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                note.font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

/// Ein Tag als Kapsel: Name mit Häkchen und Zahl der Kapitel, daneben der
/// Knopf für Plus oder Minus. Der Rest der Kapsel öffnet die Tag-Seite.
private struct MacTagPill: View {

    let tag: Tag
    let count: Int
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let followed = tag.isFollowed
        HStack(spacing: 0) {
            NavigationLink { TagDetailView(tagID: tag.id) } label: {
                HStack(spacing: Design.Spacing.small) {
                    if followed {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    Text(tag.label).fontWeight(.medium)
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, Design.Spacing.control + Design.Spacing.micro)
                .padding(.trailing, Design.Spacing.small)
                .frame(minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text("^[\(count) Kapitel](inflect: true)"))
            .accessibilityLabel(followed
                ? Text("\(tag.label), ^[\(count) Kapitel](inflect: true), du folgst")
                : Text("\(tag.label), ^[\(count) Kapitel](inflect: true)"))
            .accessibilityHint("Öffnet die Seite des Tags")
            .accessibilityIdentifier("tags.row.\(tag.testKey)")

            MacTagFollowButton(tag: tag)
                .padding(.trailing, Design.Spacing.micro)
        }
        .font(.callout)
        .foregroundStyle(followed ? Color.accentColor : Color.primary)
        .background {
            Capsule().fill(fill(followed: followed))
        }
        .overlay {
            Capsule().strokeBorder(followed ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: followed)
    }

    private func fill(followed: Bool) -> Color {
        if followed { return Color.accentColor.opacity(hovering ? 0.22 : 0.14) }
        return Color.primary.opacity(hovering ? 0.10 : 0.05)
    }
}

/// Plus oder Minus als kleiner runder Knopf mit Hover und Tooltip.
private struct MacTagFollowButton: View {

    let tag: Tag
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let follows = tag.isFollowed
        Button {
            Task { await model.setTagStance(follows ? .neutral : .follow, for: tag.id) }
        } label: {
            Image(systemName: follows ? "minus" : "plus")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help(follows ? Text("Nicht mehr folgen") : Text("Folgen"))
        .accessibilityLabel(follows ? Text("\(tag.label) nicht mehr folgen") : Text("\(tag.label) folgen"))
        .accessibilityHint(follows ? Text("Minus beendet das Folgen, das Tag bleibt.") : Text("Plus nimmt das Tag in „Für dich“ auf."))
        .accessibilityIdentifier(follows ? "tag.unfollow.\(tag.testKey)" : "tag.follow.\(tag.testKey)")
    }
}

/// „Angesagt“: eine Karte mit einer Zeile je Tag und dem Grund darunter.
private struct MacTrendingList: View {

    let entries: [TrendingTag]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, Design.Spacing.standard) }
                MacTrendingRow(entry: entry)
            }
        }
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: Design.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.control)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: Design.Radius.control))
    }
}

private struct MacTrendingRow: View {

    let entry: TrendingTag
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            NavigationLink { TagDetailView(tagID: entry.tag.id) } label: {
                HStack(spacing: Design.Spacing.control) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.tag.label).fontWeight(.medium)
                        Text(TrendText.caption(entry.trend))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet die Seite des Tags")
            .accessibilityIdentifier("tags.trending.\(entry.tag.testKey)")
            MacTagFollowButton(tag: entry.tag)
        }
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.vertical, Design.Spacing.control)
        .background(Color.primary.opacity(hovering ? 0.04 : 0))
        .onHover { hovering = $0 }
    }
}
#endif
