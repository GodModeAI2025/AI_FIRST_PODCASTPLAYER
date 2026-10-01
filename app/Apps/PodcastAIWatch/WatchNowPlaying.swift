//
//  WatchNowPlaying.swift
//  PodcastAI (Apple Watch)
//
//  „Wiedergabe“: Play/Pause, Sprünge, Tempo, Schlaf-Timer, Kapitel, Als
//  Nächstes. Alle Texte wachsen mit Dynamic Type, die Ansicht scrollt.
//

import SwiftUI
import PodcastAIPlayerKit

struct WatchNowPlayingView: View {

    @Environment(PlayerSession.self) private var session

    private var engine: PlaybackEngine { session.engine }

    var body: some View {
        ScrollView {
            if let item = engine.current {
                VStack(spacing: 8) {
                    header(item)
                    transport
                    progress
                    options
                    if case .failed(let message) = engine.state {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Läuft nichts", systemImage: "waveform")
                } description: {
                    Text("Tippe in „Neu“ oder bei deinen Abos auf eine Folge.")
                }
            }
        }
        .navigationTitle("Wiedergabe")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ item: PlayerItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            PlayerArtwork(url: item.artworkURL, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(3)
                Text(engine.currentChapter?.title ?? item.showTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        VStack(spacing: 2) {
            ProgressView(value: engine.duration > 0 ? min(engine.position / engine.duration, 1) : 0)
            HStack {
                Text(PlayerFormat.clock(engine.position))
                Spacer()
                if engine.duration > 0 {
                    Text("−" + PlayerFormat.clock(max(0, engine.duration - engine.position)))
                }
            }
            .font(.caption2.monospacedDigit())
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
        HStack(spacing: 10) {
            Button {
                engine.skip(by: -PlaybackEngine.skipBackSeconds)
            } label: {
                Image(systemName: "gobackward.15").font(.title3)
            }
            .accessibilityLabel(Text("15 Sekunden zurück"))

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying || engine.state == .loading ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(minWidth: 36, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(Text(engine.isPlaying || engine.state == .loading ? "Pause" : "Wiedergabe"))

            Button {
                engine.skip(by: PlaybackEngine.skipForwardSeconds)
            } label: {
                Image(systemName: "goforward.30").font(.title3)
            }
            .accessibilityLabel(Text("30 Sekunden vor"))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var options: some View {
        VStack(spacing: 6) {
            Button {
                engine.cycleSpeed()
            } label: {
                Label(PlaybackSpeed.label(engine.speed), systemImage: "gauge.with.dots.needle.67percent")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(Text("Tempo"))
            .accessibilityValue(Text(PlaybackSpeed.label(engine.speed)))

            NavigationLink(value: WatchRoute.sleepTimer) {
                Label {
                    if let timer = engine.sleepTimer {
                        if let remaining = timer.remaining {
                            Text("Schlaf-Timer \(PlayerFormat.clock(remaining))")
                        } else {
                            Text("Schlaf-Timer am Ende")
                        }
                    } else {
                        Text("Schlaf-Timer")
                    }
                } icon: {
                    Image(systemName: "moon.zzz")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !engine.chapters.isEmpty {
                NavigationLink(value: WatchRoute.chapters) {
                    Label("Kapitel", systemImage: "list.number")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            NavigationLink(value: WatchRoute.upNext) {
                Label("Als Nächstes", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.footnote)
    }
}

struct WatchChaptersView: View {
    @Environment(PlayerSession.self) private var session

    var body: some View {
        let engine = session.engine
        List(Array(engine.chapters.enumerated()), id: \.offset) { _, chapter in
            Button {
                engine.jump(to: chapter)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(.footnote.weight(chapter == engine.currentChapter ? .bold : .regular))
                        .lineLimit(3)
                    Text(PlayerFormat.clock(chapter.start.seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityAddTraits(chapter == engine.currentChapter ? .isSelected : [])
        }
        .navigationTitle("Kapitel")
    }
}

struct WatchSleepTimerView: View {
    @Environment(PlayerSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let engine = session.engine
        List {
            if engine.sleepTimer != nil {
                Button(role: .destructive) {
                    engine.setSleepTimer(nil)
                    dismiss()
                } label: {
                    Label("Ausschalten", systemImage: "moon.zzz.fill")
                }
            }
            ForEach(SleepTimerSetting.choices, id: \.self) { setting in
                Button {
                    engine.setSleepTimer(setting)
                    dismiss()
                } label: {
                    HStack {
                        Text(setting.title)
                        Spacer()
                        if engine.sleepTimer?.setting == setting {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityAddTraits(engine.sleepTimer?.setting == setting ? .isSelected : [])
            }
        }
        .navigationTitle("Schlaf-Timer")
    }
}
