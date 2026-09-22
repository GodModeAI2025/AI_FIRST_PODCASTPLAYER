//
//  AutoRefresh.swift
//  PodcastAI
//
//  Feeds aktualisieren sich von selbst: beim Start, beim Zurückkehren in die
//  App, wenn der letzte Lauf eine Viertelstunde her ist, und alle 30 Minuten,
//  solange die App offen ist. Ziehen zum Aktualisieren bleibt als Abkürzung.
//

import SwiftUI

private struct AutoRefreshModifier: ViewModifier {

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                // Kurz warten, bis `load()` die Quellen gelesen hat.
                try? await Task.sleep(for: .seconds(2))
                await model.refreshIfStale(olderThan: 0)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30 * 60))
                    guard !Task.isCancelled else { break }
                    await model.refreshIfStale()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshIfStale() }
            }
    }
}

extension View {
    func autoRefresh() -> some View { modifier(AutoRefreshModifier()) }
}
