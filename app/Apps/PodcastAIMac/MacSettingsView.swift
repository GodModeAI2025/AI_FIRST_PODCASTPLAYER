//
//  MacSettingsView.swift
//  PodcastAI (macOS)
//
//  Das Einstellungsfenster. Dieselben Abschnitte wie auf iOS: zwei
//  Fassungen desselben Schalters driften, und gedriftet wäre er genau
//  dort, wo es um Einwilligung geht.
//

import SwiftUI
import PodcastAIKit

struct MacSettingsView: View {

    /// Der Reiter, den das Fenster zeigt. Gespeichert, damit die Hilfe mit
    /// „Zeig es mir“ gleich den Reiter „Agenten“ öffnen kann.
    enum Tab: String {
        case general, intelligence, data, privacy, agents
    }
    static let tabKey = "settings.tab"

    let mcpAccess: MCPAccess
    @Environment(AppModel.self) private var model
    @AppStorage(MacSettingsView.tabKey) private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            Form {
                PlaybackSettingsSection(player: model.episodePlayer)
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }
            .tag(Tab.general)
            .frame(width: 520)

            Form {
                IntelligenceSettingsSection()
                AutomaticAnalysisSection()
                YouTubeTranscriptSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Intelligenz", systemImage: "sparkles") }
            .tag(Tab.intelligence)
            .frame(width: 520)

            Form {
                SyncSettingsSection()
                StorageSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Daten", systemImage: "icloud") }
            .tag(Tab.data)
            .frame(width: 520)

            Form {
                SpotlightSettingsSection()
                MacLegalSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Datenschutz", systemImage: "hand.raised") }
            .tag(Tab.privacy)
            .frame(width: 520)

            // Eine Anleitung in drei Schritten mit Texten zum Kopieren. Sie
            // braucht mehr Höhe als die anderen Reiter.
            MCPSettingsView(access: mcpAccess)
                .tabItem { Label("Agenten", systemImage: "terminal") }
                .tag(Tab.agents)
                .frame(width: 520, height: 640)
        }
        .frame(minHeight: 360)
    }
}

/// Sprungweiten für Zurück und Vor. Gelten auch für die Medientasten und
/// bleiben über einen Neustart erhalten.
private struct PlaybackSettingsSection: View {

    @Bindable var player: EpisodePlayer

    var body: some View {
        Section("Wiedergabe") {
            Picker("Zurückspringen", selection: $player.skipBackward) {
                ForEach(EpisodePlayer.skipChoices, id: \.self) { seconds in
                    Text("\(seconds) Sekunden").tag(seconds)
                }
            }
            Picker("Vorspringen", selection: $player.skipForward) {
                ForEach(EpisodePlayer.skipChoices, id: \.self) { seconds in
                    Text("\(seconds) Sekunden").tag(seconds)
                }
            }
        }
    }
}

/// Datenschutz und Impressum. Die Übersicht öffnet als Blatt, das
/// Einstellungsfenster hat keinen Stapel zum Zurückgehen.
private struct MacLegalSection: View {

    @State private var showingOverview = false

    var body: some View {
        Section {
            Button { showingOverview = true } label: {
                Label("Datenschutz in PodcastAI", systemImage: "hand.raised")
            }
            Link(destination: LegalSettingsSection.privacyPolicy) {
                Label("Datenschutzerklärung", systemImage: "doc.text")
            }
            Link(destination: LegalSettingsSection.imprint) {
                Label("Impressum", systemImage: "building.2")
            }
        } header: {
            Text("Rechtliches")
        } footer: {
            Text("Anbieter: MOBILE BOX - App Consulting UG (haftungsbeschränkt), Karlsruhe.")
                .help("""
                    Charts und Kategorien kommen von Apple Podcasts, gesucht wird bei Apple und bei \
                    Podcast Index (podcastindex.org). Beide sehen deinen Suchbegriff und deine \
                    IP-Adresse, ein Konto gibt es bei keinem.
                    """)
        }
        .sheet(isPresented: $showingOverview) {
            NavigationStack {
                PrivacyOverviewView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showingOverview = false }
                        }
                    }
            }
            .frame(minWidth: 520, minHeight: 520)
        }
    }
}
