//
//  MacKnowledgePages.swift
//  PodcastAI
//
//  „Gemerkte Stellen“ und „Gesicherte Antworten“ auf dem Mac: Karten in
//  einem Raster mit Kopf, Zahl und einem Satz, darunter jede Stelle oder
//  Antwort als Karte mit Hover und Fokus. Nur macOS, die iPhone-Listen
//  bleiben, wie sie sind.
//
//  Eine Karte öffnet die Folge oder die Antwort. Abgespielt wird nur über
//  den Knopf mit der Zeitmarke.
//

#if os(macOS)
import SwiftUI
import PodcastAIKit

// MARK: - Gemerkte Stellen

extension KnowledgeView {

    var macContent: some View {
        MacPage {
            if model.highlights.isEmpty {
                MacEmptyState("Noch nichts gemerkt", symbol: "bookmark",
                              sentence: "Tippe beim Hören auf „Moment merken“, dann steht die Stelle mit Zeitmarke und Zitat hier.")
            } else {
                MacSection(header: MacSectionHeader(
                    title: Text("Deine Stellen"), count: model.highlights.count,
                    note: Text("Momente, die du beim Hören gemerkt hast, mit Zeitmarke, Zitat und Kommentar.")
                )) {
                    LazyVGrid(columns: MacGrid.columns(minimum: 420), spacing: Design.Spacing.control) {
                        ForEach(model.highlights) { highlight in
                            MacNoteCard(
                                highlight: highlight,
                                episode: episode(of: highlight),
                                playable: isPlayable(highlight),
                                gone: highlight.episodeID.map { id in availableEpisodes.map { $0[id] == nil } ?? false } ?? false,
                                edit: { edit(highlight) }
                            )
                        }
                    }
                }
            }
        }
        .yieldsAIWhileScrolling()
    }
}

/// Eine gemerkte Stelle als Karte. Mit Folge öffnet ein Klick sie, ohne
/// Folge bleibt die Karte zum Lesen. Abspielen und das Menü liegen als
/// eigene Knöpfe über der Karte, damit ein Klick darauf nichts öffnet.
private struct MacNoteCard: View {

    let highlight: Highlight
    let episode: Episode?
    let playable: Bool
    let gone: Bool
    let edit: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm

    var body: some View {
        Group {
            if let episode {
                NavigationLink {
                    EpisodeDetailView(episode: episode)
                } label: {
                    content
                }
                .buttonStyle(MacCardButtonStyle())
                .accessibilityHint("Öffnet die Folge. Abspielen und Kopieren unter Aktionen.")
            } else {
                MacHoverCard { content }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Design.Spacing.small) {
                if playable, let ms = highlight.positionMs {
                    MacPlayButton(label: "Ab \(MediaTime(milliseconds: Int64(ms)).timecode) abspielen", size: 30) {
                        NoteActions.play(highlight, model: model, confirm: confirm)
                    }
                }
                NoteActionsMenu(highlight: highlight, playable: playable, edit: edit, deletable: true)
            }
            .padding(Design.Spacing.control)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Abspielen") {
            if playable { NoteActions.play(highlight, model: model, confirm: confirm) }
        }
        .accessibilityAction(named: "Mit Quelle kopieren") {
            Clipboard.copy(model.noteCitation(highlight))
            confirm(NoteFeedback.copied)
        }
        .contextMenu {
            NoteActions(highlight: highlight, playable: playable, edit: edit, deletable: true)
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            NoteRow(highlight: highlight, episodeGone: gone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            // Platz für die Knöpfe, die über der Karte liegen.
            Color.clear.frame(width: playable ? 72 : 32, height: 30)
        }
        .padding(Design.Spacing.standard)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
    }
}

// MARK: - Gesicherte Antworten

extension TrailListView {

    var macContent: some View {
        MacPage {
            if model.trails.isEmpty {
                MacEmptyState("Keine gesicherten Antworten", symbol: "map",
                              sentence: "Im Chat steht an jeder Antwort „Antwort sichern“, dann liegt sie mit ihren Belegen hier.")
            } else {
                MacSection(header: MacSectionHeader(
                    title: Text("Deine Antworten"), count: model.trails.count,
                    note: Text("Eine gesicherte Antwort hält eine Frage mit ihren Belegen und Notizen fest. Aufbewahrt, nicht zugestimmt.")
                )) {
                    LazyVGrid(columns: MacGrid.columns(minimum: 420), spacing: Design.Spacing.control) {
                        ForEach(model.trails) { trail in
                            MacTrailCard(trail: trail, noteCount: model.notes(of: trail).count)
                                .contextMenu {
                                    Button(role: .destructive) { model.removeTrail(trail.id) } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
    }
}

/// Eine gesicherte Antwort als Karte: Frage, Anfang der Antwort, Belege und
/// Datum. Ein Klick öffnet sie.
private struct MacTrailCard: View {

    let trail: KnowledgeTrail
    let noteCount: Int

    var body: some View {
        NavigationLink {
            TrailDetailView(trailID: trail.id)
        } label: {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
                    Image(systemName: "map")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(trail.question)
                        .font(.headline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if let answer = trail.answerText {
                    Text(answer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Design.Spacing.standard)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
        .buttonStyle(MacCardButtonStyle())
        .accessibilityElement(children: .combine)
    }

    private var details: String { TrailRow.details(of: trail, noteCount: noteCount) }
}
#endif
