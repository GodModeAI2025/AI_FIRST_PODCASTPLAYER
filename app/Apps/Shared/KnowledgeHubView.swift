//
//  KnowledgeHubView.swift
//  PodcastAI
//
//  Der Sammelpunkt für alles, was nicht Hören ist: gemerkte Stellen,
//  gesicherte Antworten, Interessen.
//
//  Bereiche, die eine Tab Bar gesprengt hätten, aber inhaltlich
//  zusammengehören. Hier bekommen sie eine Ebene, statt oben um Platz zu
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
                        title: String(localized: "Gemerkte Stellen"),
                        detail: model.highlights.isEmpty
                            ? String(localized: "Noch nichts gemerkt")
                            : model.highlights.count.formatted(),
                        symbol: "bookmark",
                        tint: .orange
                    )
                }
                NavigationLink(value: HubDestination.trails) {
                    HubRow(
                        title: String(localized: "Gesicherte Antworten"),
                        detail: model.trails.isEmpty ? String(localized: "Noch keine") : model.trails.count.formatted(),
                        symbol: "map",
                        tint: .green
                    )
                }
            } header: {
                Text("Gesammelt")
            }

            Section {
                NavigationLink(value: HubDestination.interests) {
                    HubRow(
                        title: String(localized: "Meine Tags"),
                        detail: String(localized: "\(model.profile.followed.count) gefolgt"),
                        symbol: "tag",
                        tint: .blue
                    )
                }
            } header: {
                Text("Profil")
            } footer: {
                // „Warum sehe ich das?“ beginnt hier — und das gehört gesagt.
                Text("""
                    Bestimmt, welche Stellen dir als relevant angezeigt werden. \
                    Jederzeit einsehbar und korrigierbar.
                    """)
            }

            #if os(iOS)
            // Auf dem Mac liegen die Einstellungen im Programmmenü. Auf iOS
            // gab es sie gar nicht — Modellstatus, Lernschalter und der
            // Spotlight-Schalter waren nur auf einem der beiden Geräte
            // erreichbar. Der Hauptweg ist inzwischen das Zahnrad in „Für
            // dich“ und „Meine Podcasts“; diese Zeile bleibt als zweiter.
            Section {
                NavigationLink(value: HubDestination.settings) {
                    HubRow(
                        title: String(localized: "Einstellungen"),
                        detail: String(localized: "Mobilfunk, Speicher, Datenschutz"),
                        symbol: "gearshape",
                        tint: .gray
                    )
                }
            }
            #endif

            Section {
                NavigationLink(value: HubDestination.help) {
                    HubRow(title: String(localized: "So funktioniert's"),
                           detail: String(localized: "Einsteiger bis Experten"),
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
            case .interests: TagsView()
            case .help: HelpView()
            #if os(iOS)
            case .settings: SettingsView()
            #endif
            }
        }
    }

    enum HubDestination: Hashable {
        case highlights, trails, interests, help
        #if os(iOS)
        case settings
        #endif
    }
}

/// Eine Zeile im Sammelpunkt.
///
/// Farbe trägt hier keine Information allein: jede Zeile hat Symbol **und**
/// Beschriftung. Wer Farben nicht unterscheiden kann, verliert nichts.
///
/// Titel und Detail kommen fertig übersetzt an (`String(localized:)`),
/// Zahlen über `formatted()`. `Text` zeigt sie so, wie sie sind.
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
