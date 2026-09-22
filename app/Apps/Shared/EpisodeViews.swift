//
//  EpisodeViews.swift
//  PodcastAI
//
//  Folgenliste und Erschliessung.
//
//  Die App bereitet die jüngsten Folgen einer Quelle von selbst vor: laden,
//  transkribieren, Belege mit Zeitmarken. Ohne das bleibt „Für dich“ leer,
//  und die Suche findet nichts. Ältere Folgen wartet sie ab, bis jemand sie
//  anfordert, und in den Einstellungen lässt sich das Vorbereiten ganz
//  abschalten. An jeder Folge steht deshalb sichtbar, in welchem Zustand
//  sie ist.
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

            // Zum YouTube-Kanal gibt es oft denselben Inhalt als Audio-Podcast.
            // Dessen Folgen lassen sich laden und transkribieren.
            if let counterparts = model.podcastCounterparts[sourceID], !counterparts.isEmpty {
                Section {
                    ForEach(counterparts) { podcast in
                        Button {
                            Task { await model.addSource(from: podcast.feedURL.absoluteString) }
                        } label: {
                            VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                                Label("\(podcast.title) abonnieren", systemImage: "plus.circle")
                                Text(podcast.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Als Audio-Podcast verfügbar")
                } footer: {
                    Text("Der Audio-Podcast liefert die Tonspur, die PodcastAI transkribieren darf. "
                         + "Das Audio der YouTube-Videos selbst lädt die App nicht.")
                }
            }

            Section {
                ForEach(episodes) { episode in
                    NavigationLink {
                        EpisodeDetailView(episode: episode)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .swipeActions(edge: .leading) {
                        Button { model.playEpisode(episode) } label: {
                            Label("Abspielen", systemImage: "play.fill")
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { model.addToUpNext(episode) } label: {
                            Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .tint(.indigo)
                        if episode.audioURL != nil, model.stages[episode.id] == nil || model.stages[episode.id] == .failed {
                            Button { model.enqueueAnalysis(episode) } label: {
                                Label("Erschliessen", systemImage: "waveform.badge.magnifyingglass")
                            }
                            .tint(.teal)
                        }
                    }
                    .contextMenu {
                        Button { model.playEpisode(episode) } label: { Label("Abspielen", systemImage: "play.fill") }
                        Button { model.addToUpNext(episode) } label: {
                            Label("Als Nächstes hören", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        if episode.audioURL != nil {
                            Button { model.enqueueAnalysis(episode) } label: {
                                Label("Erschliessen", systemImage: "waveform.badge.magnifyingglass")
                            }
                        }
                    }
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
        HStack(alignment: .top, spacing: Design.Spacing.control) {
            EpisodeArtwork(url: episode.artworkURL
                           ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                           size: 56)
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

            HeardProgress(fraction: model.heardFraction(for: episode))

            if stage == nil, let waiting = model.stageDetails[episode.id] {
                Label(waiting, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.episodePlayer.episode?.id == episode.id {
                Label(model.episodePlayer.isPlaying ? "läuft gerade" : "pausiert",
                      systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }

            if !episode.canBeAnalyzed {
                // Ehrlich statt stiller Fehlschlag: ohne Audio und ohne
                // getaktetes Transkript gibt es keinen Weg zu Timecodes.
                Label("Kein Audiozugang — daraus entstehen keine Timecodes",
                      systemImage: "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        }
        .padding(.vertical, Design.Spacing.micro)
        .accessibilityElement(children: .combine)
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
        }
    }

    /// Läuft gerade etwas? Dann pulsiert das Symbol — eine Bewegung, die
    /// Arbeit anzeigt, ohne den Bildschirm zu beanspruchen.
    var isRunning: Bool {
        switch self {
        case .discovered, .mediaDownloaded, .transcribed: true
        case .evidenceExtracted, .failed: false
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
