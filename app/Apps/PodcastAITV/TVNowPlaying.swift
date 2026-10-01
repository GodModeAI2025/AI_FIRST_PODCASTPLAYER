//
//  TVNowPlaying.swift
//  PodcastAI (Apple TV)
//
//  „Wiedergabe“ mit der Siri Remote: Wiedergabetaste spielt und pausiert,
//  die Tasten der Oberfläche springen, ändern das Tempo und stellen den
//  Schlaf-Timer. Die Systemanzeige „Wiedergabe“ (Kontrollzentrum) bedient
//  dieselbe Wiedergabe über `MPRemoteCommandCenter`.
//

import SwiftUI
import PodcastAIPlayerKit

struct TVNowPlayingView: View {

    @Environment(PlayerSession.self) private var session
    @State private var showingChapters = false

    private var engine: PlaybackEngine { session.engine }

    var body: some View {
        Group {
            if let item = engine.current {
                HStack(alignment: .center, spacing: 80) {
                    PlayerArtwork(url: item.artworkURL, cornerRadius: 24)
                        .frame(width: 520, height: 520)
                        .shadow(radius: 20, y: 10)
                    VStack(alignment: .leading, spacing: 24) {
                        titles(item)
                        progress
                        transport
                        options
                        if case .failed(let message) = engine.state {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .padding(60)
            } else {
                ContentUnavailableView {
                    Label("Läuft nichts", systemImage: "waveform")
                } description: {
                    Text("Wähle bei „Abos“ oder „Neu“ eine Folge.")
                }
            }
        }
        // Die Wiedergabetaste der Fernbedienung. Ohne geladene Folge tut sie
        // nichts: ohne Handlung und ohne Folge beginnt kein Ton.
        .onPlayPauseCommand { engine.togglePlayPause() }
        .sheet(isPresented: $showingChapters) { TVChaptersView() }
    }

    private func titles(_ item: PlayerItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.title2.weight(.bold))
                .lineLimit(3)
            Text(item.showTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let chapter = engine.currentChapter {
                Label(chapter.title, systemImage: "list.number")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        VStack(spacing: 8) {
            ProgressView(value: engine.duration > 0 ? min(engine.position / engine.duration, 1) : 0)
            HStack {
                Text(PlayerFormat.clock(engine.position))
                Spacer()
                if engine.duration > 0 {
                    Text("−" + PlayerFormat.clock(max(0, engine.duration - engine.position)))
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fortschritt"))
        .accessibilityValue(Text(progressSpoken))
    }

    private var progressSpoken: String {
        let done = PlayerFormat.spoken(engine.position)
        guard engine.duration > 0 else { return done }
        return String(localized: "\(done) von \(PlayerFormat.spoken(engine.duration))")
    }

    private var transport: some View {
        HStack(spacing: 32) {
            Button {
                engine.previousChapter()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(engine.chapters.isEmpty)
            .accessibilityLabel(Text("Voriges Kapitel"))

            Button {
                engine.skip(by: -PlaybackEngine.skipBackSeconds)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .accessibilityLabel(Text("15 Sekunden zurück"))

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying || engine.state == .loading ? "pause.fill" : "play.fill")
                    .frame(minWidth: 60)
            }
            .accessibilityLabel(Text(engine.isPlaying || engine.state == .loading ? "Pause" : "Wiedergabe"))

            Button {
                engine.skip(by: PlaybackEngine.skipForwardSeconds)
            } label: {
                Image(systemName: "goforward.30")
            }
            .accessibilityLabel(Text("30 Sekunden vor"))

            Button {
                engine.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(engine.chapters.isEmpty)
            .accessibilityLabel(Text("Nächstes Kapitel"))
        }
        .font(.title2)
    }

    private var options: some View {
        HStack(spacing: 24) {
            Button {
                engine.cycleSpeed()
            } label: {
                Label(PlaybackSpeed.label(engine.speed), systemImage: "gauge.with.dots.needle.67percent")
            }
            .accessibilityLabel(Text("Tempo"))
            .accessibilityValue(Text(PlaybackSpeed.label(engine.speed)))

            Menu {
                if engine.sleepTimer != nil {
                    Button("Ausschalten", systemImage: "moon.zzz.fill") { engine.setSleepTimer(nil) }
                }
                ForEach(SleepTimerSetting.choices, id: \.self) { setting in
                    Button(setting.title) { engine.setSleepTimer(setting) }
                }
            } label: {
                if let remaining = engine.sleepTimer?.remaining {
                    Label(PlayerFormat.clock(remaining), systemImage: "moon.zzz.fill")
                } else if engine.sleepTimer != nil {
                    Label("Am Ende", systemImage: "moon.zzz.fill")
                } else {
                    Label("Schlaf-Timer", systemImage: "moon.zzz")
                }
            }

            if !engine.chapters.isEmpty {
                Button {
                    showingChapters = true
                } label: {
                    Label("Kapitel", systemImage: "list.number")
                }
            }
        }
    }
}

struct TVChaptersView: View {
    @Environment(PlayerSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let engine = session.engine
        NavigationStack {
            List(Array(engine.chapters.enumerated()), id: \.offset) { _, chapter in
                Button {
                    engine.jump(to: chapter)
                    dismiss()
                } label: {
                    HStack {
                        Text(chapter.title)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        Text(PlayerFormat.clock(chapter.start.seconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityAddTraits(chapter == engine.currentChapter ? .isSelected : [])
            }
            .navigationTitle("Kapitel")
        }
    }
}
