//
//  KnowledgeHubView.swift
//  PodcastAI
//
//  Der Sammelpunkt für alles, was nicht Hören ist: gemerkte Stellen,
//  Wissenslandkarten, Gegenpositionen, Interessen.
//
//  Vier Bereiche, die eine Tab Bar gesprengt hätten, aber inhaltlich
//  zusammengehören — hier bekommen sie eine Ebene, statt oben um Platz zu
//  konkurrieren.
//

import SwiftUI
import PodcastAIKit

struct KnowledgeHubView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                NavigationLink(value: HubDestination.highlights) {
                    HubRow(
                        title: "Gemerkte Stellen",
                        detail: model.highlights.isEmpty
                            ? "Noch nichts gemerkt"
                            : "\(model.highlights.count)",
                        symbol: "bookmark",
                        tint: .orange
                    )
                }
                NavigationLink(value: HubDestination.trails) {
                    HubRow(
                        title: "Wissenslandkarten",
                        detail: model.trails.isEmpty ? "Keine geparkt" : "\(model.trails.count)",
                        symbol: "map",
                        tint: .green
                    )
                }
            } header: {
                Text("Gesammelt")
            }

            Section {
                NavigationLink(value: HubDestination.counterpoint) {
                    HubRow(
                        title: "Gegenpositionen",
                        detail: "Eine These prüfen",
                        symbol: "arrow.left.arrow.right",
                        tint: .purple
                    )
                }
            } header: {
                Text("Prüfen")
            } footer: {
                Text("PodcastAI sucht belegte Positionen zu deiner These — dafür und dagegen. "
                     + "Ziel ist dein eigenes Urteil, nicht eine bestimmte Meinung.")
            }

            Section {
                NavigationLink(value: HubDestination.interests) {
                    HubRow(
                        title: "Interessen",
                        detail: "\(model.profile.confirmed.count) bestätigt",
                        symbol: "target",
                        tint: .blue
                    )
                }
            } header: {
                Text("Profil")
            } footer: {
                // „Warum sehe ich das?“ beginnt hier — und das gehört gesagt.
                Text("Bestimmt, welche Stellen dir als relevant angezeigt werden. "
                     + "Jederzeit einsehbar und korrigierbar.")
            }

            #if os(iOS)
            // Auf dem Mac liegen die Einstellungen im Programmmenü. Auf iOS
            // gab es sie gar nicht — Modellstatus, Lernschalter und der
            // Spotlight-Schalter waren nur auf einem der beiden Geräte
            // erreichbar.
            Section {
                NavigationLink(value: HubDestination.settings) {
                    HubRow(
                        title: "Einstellungen",
                        detail: "Vorbereiten, Intelligenz, Lernen, Systemsuche",
                        symbol: "gearshape",
                        tint: .gray
                    )
                }
            }
            #endif

            Section {
                NavigationLink(value: HubDestination.help) {
                    HubRow(title: "So funktioniert's", detail: "Einsteiger bis Experten",
                           symbol: "questionmark.circle", tint: .teal)
                }
            }
        }
        .navigationTitle("Wissen")
        .activityStatusToolbar()
        .navigationDestination(for: HubDestination.self) { destination in
            switch destination {
            case .highlights: KnowledgeView()
            case .trails: TrailListView()
            case .counterpoint: CounterpointView()
            case .interests: InterestsView()
            case .help: HelpView()
            #if os(iOS)
            case .settings: SettingsView()
            #endif
            }
        }
    }

    enum HubDestination: Hashable {
        case highlights, trails, counterpoint, interests, help
        #if os(iOS)
        case settings
        #endif
    }
}

/// Eine Zeile im Sammelpunkt.
///
/// Farbe trägt hier keine Information allein: jede Zeile hat Symbol **und**
/// Beschriftung. Wer Farben nicht unterscheiden kann, verliert nichts.
struct HubRow: View {

    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: RoundedRectangle(
                    cornerRadius: Design.Radius.chip, style: .continuous
                ))
                .accessibilityHidden(true)

            Text(title)

            Spacer(minLength: Design.Spacing.small)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Design.Spacing.micro)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }
}
