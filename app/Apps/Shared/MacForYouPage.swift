//
//  MacForYouPage.swift
//  PodcastAI
//
//  „Für dich“ auf dem Mac: Abschnitte mit Zahl und einem Satz, darunter
//  Kacheln in einem Raster statt einer Zeile je Eintrag. Weiterhören, neue
//  Folgen aus den Abos und die Stellen zu deinen Tags füllen die Breite des
//  Fensters. Nur macOS, die iPhone-Liste in `Views.swift` bleibt, wie sie ist.
//
//  Eine Kachel öffnet. Ton startet nur, was jemand anklickt.
//

#if os(macOS)
import SwiftUI
import PodcastAIKit

extension ForYouView {

    var macContent: some View {
        MacPage {
            let resume = model.continueListening
            let fresh = model.freshEpisodes
            let showsTags = !model.sources.isEmpty && !model.profile.followed.isEmpty

            if !resume.isEmpty {
                MacSection(header: MacSectionHeader(
                    title: Text("Weiterhören"), count: resume.count, note: Text(Self.resumeExplanation)
                )) {
                    LazyVGrid(columns: MacGrid.columns(minimum: 300), spacing: Design.Spacing.control) {
                        ForEach(resume, id: \.episode.id) { entry in
                            ResumeTile(episode: entry.episode, position: entry.position)
                        }
                    }
                }
            }

            if !fresh.isEmpty {
                MacSection(header: MacSectionHeader(
                    title: Text("Neu in deinen Abos"), count: fresh.count,
                    note: Text("Die neuesten Folgen der Podcasts, die du abonniert hast.")
                )) {
                    LazyVGrid(columns: MacGrid.columns(minimum: 300), spacing: Design.Spacing.control) {
                        ForEach(fresh) { episode in MacFreshTile(episode: episode) }
                    }
                }
            }

            if model.sources.isEmpty {
                MacEmptyState("Noch keine Podcasts", symbol: "mic",
                              sentence: "Abonniere deine Lieblingssendungen, dann stehen hier neue Folgen und die Stellen zu deinen Tags.") {
                    Button("Podcast suchen") { addingSource = true }
                        .buttonStyle(.prominentAction)
                }
            } else if !showsTags {
                // Ohne gefolgte Tags gibt es keine Stellen. Stehen auch keine
                // Folgen da, sagt die Seite, wie sie sich füllt.
                if resume.isEmpty && fresh.isEmpty {
                    MacEmptyState("Noch nichts für dich", symbol: "rectangle.stack",
                                  sentence: "Folge einem Tag, dann sammelt diese Seite die passenden Kapitel.") {
                        NavigationLink("Meine Tags") { TagsView() }
                            .buttonStyle(.prominentAction)
                    }
                }
            } else {
                macTagsSection
            }

            // Gemerkte Stellen auch von hier, nicht nur in der Seitenleiste.
            if !model.highlights.isEmpty {
                NavigationLink { KnowledgeView() } label: {
                    HStack(spacing: Design.Spacing.control) {
                        Image(systemName: "bookmark.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text("Gemerkte Stellen").font(.body.weight(.medium))
                        Spacer(minLength: Design.Spacing.small)
                        Text(model.highlights.count, format: .number)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(Design.Spacing.standard)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacCardButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("forYou.highlights")
            }
        }
        .yieldsAIWhileScrolling()
    }

    /// Die Stellen zu den Tags, denen du folgst, je Tag eine Gruppe.
    private var macTagsSection: some View {
        let header = MacSectionHeader(
            title: Text("Zu deinen Tags"),
            note: Text("Kapitel aus deinen Folgen, die zu Tags passen, denen du folgst.")
        ) {
            NavigationLink { TagsView() } label: {
                Text("Tags bearbeiten").font(.callout)
            }
            .accessibilityIdentifier("forYou.interests")
        }
        return MacSection(header: header) {
            if model.relevantToday.isEmpty {
                Label("Gerade keine ungehörten Stellen. Neue kommen dazu, sobald weitere Transkripte fertig sind.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(Design.Spacing.standard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .macCard()
            } else {
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    ForEach(groupedRelevant) { group in
                        VStack(alignment: .leading, spacing: Design.Spacing.small) {
                            group.header
                            LazyVGrid(columns: MacGrid.columns(minimum: 420), spacing: Design.Spacing.control) {
                                ForEach(group.cards) { card in
                                    MacRelevantCard(card: card, groupLabel: group.label)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Eine Karte mit Treffern zu einem Tag. Die Karte selbst ist die
/// Zeile aus der iPhone-Liste, hier mit Hover und Akzentrand beim
/// Überfahren. Ein Klick öffnet die Folge, abgespielt wird nur über den
/// Knopf mit der Zeitmarke.
private struct MacRelevantCard: View {

    let card: RelevantCard
    let groupLabel: String
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RelevantItemRow(bundle: card, groupLabel: groupLabel)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.45 : 0), lineWidth: 1)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}
#endif
