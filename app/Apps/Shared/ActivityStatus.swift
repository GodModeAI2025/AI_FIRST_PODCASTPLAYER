//
//  ActivityStatus.swift
//  PodcastAI
//
//  Was im Hintergrund läuft, als kleines Symbol in der Navigationsleiste.
//  Eine Zeile über dem Inhalt schob beim Erscheinen die Navigation nach
//  unten und verdeckte Knöpfe. Das Symbol hat einen festen Platz, ein
//  Tipp öffnet die Warteschlange mit allen Einzelheiten.
//

import SwiftUI
import PodcastAIKit

extension EnvironmentValues {
    /// Öffnet die Warteschlange. Gesetzt von der Wurzelansicht.
    @Entry var openQueue: (@MainActor @Sendable () -> Void)? = nil
}

struct ActivityStatusButton: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openQueue) private var openQueue

    private var pending: Int { model.analysisQueue.count + (model.analyzing == nil ? 0 : 1) }

    var body: some View {
        if model.activity != nil || pending > 0 {
            Button { openQueue?() } label: {
                HStack(spacing: Design.Spacing.micro) {
                    ProgressView().controlSize(.small)
                    if pending > 0 {
                        Text("\(pending)").font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Öffnet die Warteschlange")
            .accessibilityIdentifier("activity.status")
        }
    }

    private var accessibilityText: String {
        if pending > 0 {
            return pending == 1 ? "Eine Folge wird vorbereitet" : "\(pending) Folgen werden vorbereitet"
        }
        return model.activity ?? "Arbeit läuft"
    }
}

extension View {
    /// Fügt das Aktivitätssymbol in die Navigationsleiste ein.
    func activityStatusToolbar() -> some View {
        toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { ActivityStatusButton() }
            #else
            ToolbarItem(placement: .navigation) { ActivityStatusButton() }
            #endif
        }
    }
}
