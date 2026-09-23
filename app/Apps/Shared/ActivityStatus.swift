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

    /// Was läuft oder gleich laufen darf.
    private var pending: Int { model.runnableQueueCount + (model.analyzing == nil ? 0 : 1) }
    /// Was auf ein passendes Netz wartet.
    private var waiting: Int { model.analysisQueue.count - model.runnableQueueCount }

    var body: some View {
        if model.activity != nil || pending > 0 || waiting > 0 {
            Button { openQueue?() } label: {
                HStack(spacing: Design.Spacing.micro) {
                    if model.activity != nil || pending > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        // Nichts läuft, alles wartet: ein ruhiges Symbol statt eines Kreisels.
                        Image(systemName: model.preparationWait?.symbol ?? "clock")
                    }
                    let count = pending > 0 ? pending : waiting
                    if count > 0 {
                        Text(count, format: .number).font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Öffnet die Warteschlange")
            .accessibilityIdentifier("activity.status")
        }
    }

    /// Das Verb richtet sich hier nach der Zahl („wird“, „werden“). Die
    /// automatische Beugung hilft da nicht, deshalb stehen Einzahl und
    /// Mehrzahl als eigene Sätze da.
    private var accessibilityText: String {
        if pending > 0 {
            return pending == 1
                ? String(localized: "Für eine Folge wird das Transkript erstellt")
                : String(localized: "Für \(pending) Folgen werden Transkripte erstellt")
        }
        if let activity = model.activity { return activity }
        if waiting > 0 {
            let count = waiting == 1
                ? String(localized: "Eine Folge wartet")
                : String(localized: "\(waiting) Folgen warten")
            return model.preparationWait.map { String(localized: "\(count). \($0.settingsLabel)") } ?? count
        }
        return String(localized: "Arbeit läuft")
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
