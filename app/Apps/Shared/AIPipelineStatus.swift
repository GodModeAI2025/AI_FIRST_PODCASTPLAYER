//
//  AIPipelineStatus.swift
//  PodcastAI
//
//  Was die eine Stelle für Apple Intelligence (`AIScheduler`) gerade tut,
//  für die Warteschlange. Ein eigenes beobachtbares Objekt: ein neuer Stand
//  zeichnet nur die Zeile neu, die ihn liest, nicht die Listen der App.
//
//  Dazu die Signale aus der Oberfläche: Scrollt eine Liste, wartet die Arbeit
//  im Hintergrund, und im Stromsparmodus ruht sie, solange Ton läuft
//  (`EpisodePlayer.isPlaying`, Meldung zum Stromsparmodus).
//

import SwiftUI
import PodcastAIKit

@MainActor
@Observable
final class AIPipelineStatus {

    private(set) var snapshot = AIPipelineSnapshot()
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var powerObserver: (any NSObjectProtocol)?

    /// Einmal beim Start. Übernimmt jeden neuen Stand in einem Schritt und
    /// achtet auf den Stromsparmodus.
    func follow(player: EpisodePlayer) {
        guard following == nil else { return }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated { Self.updateHold(playing: player?.isPlaying ?? false) }
        }
        following = Task { [weak self] in
            for await next in AIScheduler.shared.snapshots {
                guard let self else { return }
                if next != self.snapshot { self.snapshot = next }
            }
        }
    }

    /// Eine Zeile für die Warteschlange, oder nichts, wenn die Stelle ruht.
    var summary: String? {
        let waiting = snapshot.queuedCount
        if let running = snapshot.running {
            let name = Self.name(of: running)
            guard waiting > 0 else { return String(localized: "Apple Intelligence: \(name)") }
            return String(localized: "Apple Intelligence: \(name), danach noch \(waiting)")
        }
        guard waiting > 0 else { return nil }
        // Wartet sie, dann auf Ruhe in der Oberfläche oder auf die kurze Pause.
        return String(localized: "Apple Intelligence wartet auf eine ruhige Sekunde, dann noch \(waiting)")
    }

    static func name(of kind: AIWorkKind) -> String {
        switch kind {
        case .answer: String(localized: "Antwort im Chat")
        case .chapterSummary: String(localized: "Satz je Kapitel")
        case .facts: String(localized: "Fakten")
        case .tags: String(localized: "Tags je Kapitel")
        case .relevance: String(localized: "Relevanz prüfen")
        case .other: String(localized: "Sonstiges")
        }
    }

    /// Im Stromsparmodus teilt sich das Modell das Gerät nicht mit laufendem Ton.
    static func updateHold(playing: Bool) {
        AIScheduler.shared.setBackgroundHeld(playing && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

extension View {
    /// Solange diese Liste scrollt, beginnt keine Arbeit von Apple Intelligence
    /// im Hintergrund, und danach erst nach zwei ruhigen Sekunden.
    func yieldsAIWhileScrolling() -> some View {
        onScrollPhaseChange { _, phase in
            AIScheduler.shared.noteScrolling(phase != .idle)
        }
    }
}
