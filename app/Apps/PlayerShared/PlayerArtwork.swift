//
//  PlayerArtwork.swift
//  Gemeinsam für Apple Watch und Apple TV (nicht in der iOS- und Mac-App).
//
//  Cover und Zeitangaben. Ohne Texte, damit jede App ihren eigenen String
//  Catalog behält.
//

import SwiftUI
import PodcastAIPlayerKit

/// Ein Cover. Ohne Bild oder beim Laden steht ein ruhiges Platzhalterbild.
/// Für VoiceOver ist es ohne Bedeutung: der Titel steht daneben.
struct PlayerArtwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        AsyncImage(url: url.map(SafeHTTP.secureVariant(of:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

enum PlayerFormat {

    /// „1:02:03“ oder „4:05“.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Länge für Listen, etwa „30 Min“ oder „1 Std 5 Min“.
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds.isFinite ? seconds : 0) / 60))
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }

    /// Länge in Worten für VoiceOver, etwa „1 Stunde, 2 Minuten“.
    static func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.isFinite ? seconds : 0))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
    }

    /// Erscheinungsdatum, kurz.
    static func date(_ date: Date?) -> String? {
        date?.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
