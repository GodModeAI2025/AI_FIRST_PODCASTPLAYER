//
//  AutoRefresh.swift
//  PodcastAI
//
//  Feeds aktualisieren sich von selbst: beim Start, beim Zurückkehren in die
//  App, wenn der letzte Lauf eine Viertelstunde her ist, und alle 30 Minuten,
//  solange die App läuft. Ziehen zum Aktualisieren bleibt als Abkürzung.
//
//  Der Takt hängt am Start der App, nicht an einem Fenster. Auf dem Mac
//  läuft die App weiter, wenn das letzte Fenster zu ist, und mit mehreren
//  Fenstern gab es sonst mehrere Takte.
//

import SwiftUI

@MainActor
enum AutoRefresh {

    /// Einmal gleich, danach alle 30 Minuten, bis die Aufgabe endet.
    ///
    /// Erst nach `load()` aufrufen. Vorher kennt das Modell keine Quellen,
    /// und `refreshIfStale` kehrt ohne Aktualisierung zurück.
    static func run(for model: AppModel) async {
        await model.refreshIfStale(olderThan: 0)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled else { break }
            await model.refreshIfStale()
        }
    }
}

private struct AutoRefreshModifier: ViewModifier {

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    // Apple Intelligence kann inzwischen bereit, abgeschaltet
                    // oder das Kontingent aufgebraucht sein.
                    await model.refreshModelStatus()
                    await model.refreshIfStale()
                }
            }
    }
}

extension View {
    func autoRefresh() -> some View { modifier(AutoRefreshModifier()) }
}
