//
//  CoverView.swift
//  PodcastAI
//
//  Das Cover einer persönlichen Ausgabe.
//
//  `NativeCoverRenderer` und `CoverAsset` waren geschrieben und hatten null
//  Aufrufstellen — Kapitel 7 („Titel, Shownotes, Kapitel, Cover“) gab es
//  damit im Quelltext, aber nicht in der App.
//
//  Gespeichert wird nichts: ein Layoutcover ist eine **reine Funktion** aus
//  Ausgabe und Feedtitel (`id: "cover-<batchKey>"`, Farbe deterministisch
//  aus dem Titel). Was sich jederzeit identisch neu berechnen lässt, gehört
//  nicht in die Datenbank — es müsste sonst bei jeder Änderung nachgezogen
//  werden und könnte veralten.
//
//  Kein generiertes Bild ohne Zustimmung: `nativeLayout` ist Typografie und
//  Farbe, sonst nichts. Image Playground kommt nur über
//  `CoverArtworkCoordinator` und nur nach einem Systemdialog.
//

import SwiftUI
import PodcastAIKit

struct CoverView: View {

    let cover: CoverAsset
    var size: CGFloat = 88

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                    Text(cover.title)
                        .font(.system(size: size * 0.16, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    if let subtitle = cover.subtitle {
                        Text(subtitle)
                            .font(.system(size: size * 0.11, weight: .medium))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(size * 0.1)
            }
            // Pflicht, nicht Kür: `altText` ist im Modell nicht optional,
            // weil ein Cover ohne Beschreibung für VoiceOver ein leeres
            // Bild ist.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cover.altText)
            .accessibilityAddTraits(.isImage)
    }

    /// Die Palette. Der Index kommt deterministisch aus dem Feedtitel —
    /// derselbe Feed wechselt nicht bei jeder Ausgabe die Farbe.
    private var gradient: LinearGradient {
        let palette: [[Color]] = [
            [.indigo, .purple],
            [.teal, .blue],
            [.orange, .pink],
            [.green, .mint],
            [.brown, .orange],
            [.cyan, .indigo],
        ]
        let colors = palette[abs(cover.paletteIndex) % palette.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
