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

/// Öffnet die Warteschlange. Gesetzt von der Wurzelansicht.
///
/// Als Typ statt als nackte Closure: Closures lassen sich nicht vergleichen,
/// jede neue würde alle Ansichten neu zeichnen, die den Wert lesen. Die
/// Aktion bleibt für ihre Ansicht immer dieselbe.
struct OpenQueueAction: Equatable {
    let run: @MainActor @Sendable () -> Void

    @MainActor func callAsFunction() { run() }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var openQueue: OpenQueueAction? = nil
}

struct ActivityStatusButton: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openQueue) private var openQueue
    @State private var confirmingCancel = false

    /// Was läuft oder gleich laufen darf.
    private var pending: Int { model.runnableQueueCount + (model.analyzing == nil ? 0 : 1) }
    /// Was auf ein passendes Netz wartet.
    private var waiting: Int { model.analysisQueue.count - model.runnableQueueCount }
    /// Folgen, die gerade Fakten bekommen oder gleich drankommen.
    private var facts: Int { model.factsPendingCount }

    var body: some View {
        if model.queuePaused, model.queueWaitingCount > 0 {
            // Pausiert: kein Kreisel, der Arbeit vortäuscht, sondern das
            // Pausenzeichen mit der Zahl der wartenden Folgen.
            Button { openQueue?() } label: {
                HStack(spacing: Design.Spacing.micro) {
                    Image(systemName: "pause.circle")
                    Text(model.queueWaitingCount, format: .number)
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            .accessibilityLabel(model.queuePausedSummary)
            .accessibilityHint("Öffnet die Warteschlange")
            .accessibilityIdentifier("activity.status")
            .contextMenu { controls }
            .queueCancelConfirmation(isPresented: $confirmingCancel)
        } else if model.activity != nil || pending > 0 || waiting > 0 || facts > 0 {
            Button { openQueue?() } label: {
                HStack(spacing: Design.Spacing.micro) {
                    if model.activity != nil || pending > 0 || facts > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        // Nichts läuft, alles wartet: ein ruhiges Symbol statt eines Kreisels.
                        Image(systemName: model.preparationWait?.symbol ?? "clock")
                    }
                    // Transkripte zuerst, sie gehen vor. Die Fakten nennt VoiceOver dazu.
                    let count = pending > 0 ? pending : (facts > 0 ? facts : waiting)
                    if count > 0 {
                        Text(count, format: .number).font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
            }
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Öffnet die Warteschlange")
            .accessibilityIdentifier("activity.status")
            .contextMenu { controls }
            .queueCancelConfirmation(isPresented: $confirmingCancel)
        }
    }

    /// Lange drücken: dieselben Knöpfe wie oben in der Warteschlange.
    @ViewBuilder private var controls: some View {
        Button { openQueue?() } label: {
            Label("Warteschlange öffnen", systemImage: "list.bullet")
        }
        if model.queueWaitingCount > 0 || model.queuePaused {
            QueuePauseButton()
            Button(role: .destructive) { confirmingCancel = true } label: {
                Label("Alle abbrechen", systemImage: "xmark.circle")
            }
        }
    }

    /// Das Verb richtet sich hier nach der Zahl („wird“, „werden“). Die
    /// automatische Beugung hilft da nicht, deshalb stehen Einzahl und
    /// Mehrzahl als eigene Sätze da.
    private var accessibilityText: String {
        let main = transcriptText
        guard facts > 0 else { return main ?? String(localized: "Arbeit läuft") }
        // „Fakten: 2 Folgen“, hinter dem, was die Transkripte sagen.
        let factsText = String(AttributedString(localized: "Fakten: ^[\(facts) Folge](inflect: true)").characters)
        return main.map { String(localized: "\($0). \(factsText)") } ?? factsText
    }

    private var transcriptText: String? {
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
        return nil
    }
}

/// „Pausieren“ oder „Fortsetzen“, je nach Stand der Warteschlange.
struct QueuePauseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.queuePaused {
            Button { model.resumeQueue() } label: {
                Label("Fortsetzen", systemImage: "play.fill")
            }
            .accessibilityIdentifier("queue.resume")
        } else {
            Button { model.pauseQueue() } label: {
                Label("Pausieren", systemImage: "pause.fill")
            }
            .accessibilityIdentifier("queue.pause")
        }
    }
}

/// Die Rückfrage vor „Alle abbrechen“. Sagt, was bleibt und was wiederkommt.
private struct QueueCancelConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Warteschlange leeren?", isPresented: $isPresented,
                                   titleVisibility: .visible) {
            Button("Alle abbrechen", role: .destructive) {
                Task { await model.cancelQueue() }
            }
            .accessibilityIdentifier("queue.cancelAll.confirm")
        } message: {
            Text("""
                Alle wartenden Transkripte und Fakten gehen aus der Warteschlange. Was schon \
                erkannt ist, bleibt gespeichert. Von selbst eingereihte Folgen kommen erst wieder \
                dazu, wenn du von Hand aktualisierst oder sie selbst anforderst.
                """)
        }
    }
}

extension View {
    func queueCancelConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(QueueCancelConfirmation(isPresented: isPresented))
    }
}

extension AppModel {
    /// Wie viele Folgen auf die Warteschlange warten, Transkripte und Fakten
    /// zusammen, die angehaltene laufende Folge mitgezählt.
    var queueWaitingCount: Int {
        AnalysisQueueControl.waitingCount(
            running: analyzing != nil, transcripts: analysisQueue.count,
            facts: factsQueue.count + (gatheringFacts == nil ? 0 : 1))
    }

    /// „Pausiert, 12 Folgen warten“. Einzahl und Mehrzahl als eigene Sätze,
    /// weil sich das Verb mit der Zahl ändert.
    var queuePausedSummary: String {
        let count = queueWaitingCount
        switch count {
        case 0: return String(localized: "Pausiert")
        case 1: return String(localized: "Pausiert, eine Folge wartet")
        default: return String(localized: "Pausiert, \(count) Folgen warten")
        }
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
