//
//  PlayerProgress.swift
//  Gemeinsam für Apple Watch und Apple TV (nicht in der iOS- und Mac-App).
//
//  Der Fortschritt einer Folge in „Wiedergabe“. Die zwei Texte für VoiceOver,
//  „Fortschritt“ und „%@ von %@“, stehen im String Catalog jeder der beiden
//  Apps: die Datei wird in beide gebaut und liest den Katalog der App, in der
//  sie läuft.
//

import SwiftUI

/// Balken, Stelle und Restzeit. Uhr und Fernseher unterscheiden sich nur in
/// Abstand und Schrift.
struct PlayerProgress: View {
    let position: TimeInterval
    let duration: TimeInterval
    let spacing: CGFloat
    let font: Font

    var body: some View {
        VStack(spacing: spacing) {
            ProgressView(value: duration > 0 ? min(position / duration, 1) : 0)
            HStack {
                Text(PlayerFormat.clock(position))
                Spacer()
                if duration > 0 {
                    Text("−" + PlayerFormat.clock(max(0, duration - position)))
                }
            }
            .font(font.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Fortschritt"))
        .accessibilityValue(Text(spoken))
    }

    private var spoken: String {
        let done = PlayerFormat.spoken(position)
        guard duration > 0 else { return done }
        return String(localized: "\(done) von \(PlayerFormat.spoken(duration))")
    }
}
