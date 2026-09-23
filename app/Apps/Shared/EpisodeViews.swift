//
//  EpisodeViews.swift
//  PodcastAI
//
//  Folgenliste und Erschliessung.
//
//  Der wichtigste Punkt an dieser Oberfläche: **Abonnieren erschliesst
//  nichts.** Eine Folge wird erst analysiert, wenn der Nutzer es sagt —
//  das kostet Daten, Akku und Zeit, und die Entscheidung gehört ihm.
//  Deshalb steht an jeder Folge sichtbar, in welchem Zustand sie ist.
//

import SwiftUI
import PodcastAIKit

struct EpisodeListView: View {

    let sourceID: SourceID
    @Environment(AppModel.self) private var model

    private var source: Source? { model.sources.first { $0.id == sourceID } }
    private var episodes: [Episode] { model.episodes[sourceID] ?? [] }

    var body: some View {
        List {
            if !(source?.capabilities.supportsTimedKnowledge ?? true),
               let reason = source?.capabilities.limitationReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode)
                }
            } header: {
                // Gefunden und erschlossen sind getrennte Zahlen. Sie zu
                // vermischen würde behaupten, alles sei durchsuchbar.
                let analyzed = episodes.filter { model.stages[$0.id] == .evidenceExtracted }.count
                Text("\(episodes.count) gefunden · \(analyzed) erschlossen")
            }
        }
        .navigationTitle(source?.title ?? "Folgen")
        .task { await model.loadEpisodes(for: sourceID) }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "Keine Folgen",
                    systemImage: "list.bullet",
                    description: Text("In diesem Feed wurden keine Folgen gefunden.")
                )
            }
        }
    }
}

struct EpisodeRow: View {

    let episode: Episode
    @Environment(AppModel.self) private var model

    private var stage: ProcessingStage? { model.stages[episode.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text(episode.title)
                .font(.headline)
                .lineLimit(3)

            HStack(spacing: Design.Spacing.small) {
                if let published = episode.publishedAt {
                    Text(published, style: .date)
                }
                if let duration = episode.declaredDuration {
                    Text(duration.shortDescription)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let stage {
                // Der Zustand trägt Symbol **und** Text. Farbe allein würde
                // für jeden, der sie nicht unterscheiden kann, nichts sagen.
                Label {
                    Text(model.stageDetails[episode.id].map { "\(stage.label) · \($0)" }
                         ?? stage.label)
                } icon: {
                    Image(systemName: stage.symbol)
                        .symbolEffect(.pulse, isActive: stage.isRunning)
                }
                .font(.caption)
                .foregroundStyle(stage == .failed ? .orange : .secondary)
            }

            if model.isQueued(episode.id) {
                // Steht in der Warteschlange — ob gerade gearbeitet wird
                // oder gewartet, sagt die Zeile darüber. Die Handlung ist
                // dieselbe: herausnehmen.
                HStack(spacing: Design.Spacing.small) {
                    Image(systemName: model.isAnalyzing(episode.id)
                          ? "waveform.badge.magnifyingglass" : "clock")
                        .accessibilityHidden(true)
                    Text(model.isAnalyzing(episode.id)
                         ? "wird erschlossen" : "wartet auf einen freien Moment")
                    Spacer(minLength: Design.Spacing.small)
                    Button(role: .destructive) {
                        model.cancelAnalysis(episode.id)
                    } label: {
                        Text("Herausnehmen")
                            .frame(minHeight: Design.minimumTapTarget)
                    }
                    .buttonStyle(.pressable)
                }
                .font(.caption)
                .padding(.top, Design.Spacing.micro)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Der bereits gesicherte Zwischenstand bleibt erhalten.")
            } else if let audioURL = episode.audioURL,
                      stage == nil || stage == .failed || stage == .cancelled {
                Button {
                    model.requestAnalysis(episode, audioURL: audioURL)
                } label: {
                    Label(startLabel(for: stage),
                          systemImage: "waveform.badge.magnifyingglass")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.pressable)
                .buttonBorderShape(.capsule)
                .padding(.top, Design.Spacing.micro)
                .accessibilityHint("Nimmt die Folge in die Warteschlange. Die Arbeit "
                                   + "läuft weiter, auch wenn du die App verlässt.")
            } else if !episode.canBeAnalyzed {
                // Ehrlich statt stiller Fehlschlag: ohne Audio und ohne
                // getaktetes Transkript gibt es keinen Weg zu Timecodes.
                Label("Kein Audiozugang — daraus entstehen keine Timecodes",
                      systemImage: "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Design.Spacing.micro)
        .accessibilityElement(children: .combine)
    }
}

/// Die Beschriftung des Startknopfes hängt davon ab, was vorher war.
///
/// Nach einem Abbruch steht dort **„Weiter erschliessen“** — und das ist
/// jetzt die Wahrheit.
///
/// In der vorigen Fassung stand hier „Von vorn erschliessen“, weil genau
/// das passierte: ein abgebrochener Lauf begann wieder bei null. Mit den
/// Prüfpunkten in `ContentPipeline` liegt der Zwischenstand in der
/// Datenbank, die Mediendatei bleibt liegen, und der nächste Lauf setzt an
/// der gesicherten Stelle an.
private func startLabel(for stage: ProcessingStage?) -> String {
    switch stage {
    case .failed: "Erneut versuchen"
    case .cancelled: "Weiter erschliessen"
    default: "Erschliessen"
    }
}

extension ProcessingStage {

    /// Ein eigenes Symbol je Stufe, damit der Fortschritt erkennbar ist,
    /// ohne die Beschriftung zu lesen.
    var symbol: String {
        switch self {
        case .discovered: "arrow.down.circle"
        case .mediaDownloaded: "waveform"
        case .transcribed: "text.alignleft"
        case .evidenceExtracted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        }
    }

    /// Läuft gerade etwas? Dann pulsiert das Symbol — eine Bewegung, die
    /// Arbeit anzeigt, ohne den Bildschirm zu beanspruchen.
    var isRunning: Bool {
        switch self {
        case .discovered, .mediaDownloaded, .transcribed: true
        case .evidenceExtracted, .failed, .cancelled: false
        }
    }
}

// MARK: - Wissen

/// Gemerkte Stellen und ihr Weg nach draussen.
struct KnowledgeView: View {

    @Environment(AppModel.self) private var model
    @State private var exported: String?

    var body: some View {
        List {
            if model.highlights.isEmpty {
                ContentUnavailableView {
                    Label("Noch nichts gemerkt", systemImage: "bookmark")
                } description: {
                    Text("Während des Hörens kannst du eine Stelle merken — mit Quelle, "
                         + "Timecode und Originaltext.")
                }
            }
            ForEach(model.highlights) { highlight in
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    if let note = highlight.note {
                        Text(note).font(.body)
                    }
                    Text("gemerkt \(highlight.capturedVia.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Wissen")
        .toolbar {
            if !model.highlights.isEmpty {
                Button {
                    Task { exported = await model.exportKnowledge() }
                } label: {
                    Label("Als Markdown exportieren", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: Binding(
            get: { exported.map(ExportPreview.init) },
            set: { exported = $0?.text }
        )) { preview in
            ExportPreviewSheet(text: preview.text)
        }
    }
}

struct ExportPreview: Identifiable {
    let text: String
    var id: String { text }
    init(_ text: String) { self.text = text }
}

/// Der Export wird gezeigt, bevor er das Gerät verlässt.
///
/// Nicht aus Höflichkeit: ein Export kann Originalzitate und eigene Notizen
/// enthalten, und wer ihn weitergibt, sollte vorher gesehen haben, was darin
/// steht.
struct ExportPreviewSheet: View {

    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: text) { Label("Teilen", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
