//
//  MCPSettingsView.swift
//  PodcastAI (macOS)
//
//  Der Agentenzugang, sichtbar und abschaltbar.
//
//  `MCPAccess` hatte keine einzige Aufrufstelle: kein Schalter, keine
//  Freigabe, kein Protokoll zu sehen. Ein Zugang, den der Nutzer weder
//  einschalten noch nachlesen kann, ist entweder keiner oder ein
//  Hintertürchen — beides taugt nicht.
//
//  Die Reihenfolge auf dieser Seite ist die Reihenfolge der Entscheidungen:
//  erst überhaupt ein Zugang, dann worauf, dann wie lange, und darunter,
//  was tatsächlich gelesen wurde.
//

import SwiftUI
import PodcastAIKit

struct MCPSettingsView: View {

    @Environment(AppModel.self) private var model
    @State private var access: MCPAccess?
    @State private var isEnabled = false
    @State private var agentName = ""
    @State private var selectedSources: Set<SourceID> = []
    @State private var includesHighlights = false
    @State private var hours = 1

    var body: some View {
        Form {
            Section {
                Toggle("Agentenzugang erlauben", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        access?.isEnabled = newValue
                    }
            } header: {
                Text("Zugang")
            } footer: {
                Text("Nur lesend, nur lokal über die Standardeingabe. Kein Netzwerk-Port, "
                     + "kein Lauschen im Netz. Kein Werkzeug schreibt, löscht oder startet "
                     + "Wiedergabe — solche Werkzeuge gibt es nicht.")
            }

            if isEnabled {
                Section("Freigabe") {
                    TextField("Name des Agenten", text: $agentName)

                    // Quellen einzeln. „Alles“ ist kein Scope, und ein
                    // Knopf dafür wäre eine Einladung.
                    ForEach(model.sources) { source in
                        Toggle(source.title, isOn: Binding(
                            get: { selectedSources.contains(source.id) },
                            set: { on in
                                if on { selectedSources.insert(source.id) }
                                else { selectedSources.remove(source.id) }
                            }
                        ))
                    }

                    Toggle("Gemerkte Stellen und geparkte Fragen einschliessen",
                           isOn: $includesHighlights)

                    Stepper("Gültig für \(hours) \(hours == 1 ? "Stunde" : "Stunden")",
                            value: $hours, in: 1...24)

                    HStack {
                        Button("Freigeben") { authorize() }
                            .disabled(agentName.isEmpty || selectedSources.isEmpty)
                        Button("Zurückziehen", role: .destructive) { access?.revoke() }
                            .disabled(access?.grant == nil)
                    }
                }

                if let grant = access?.grant {
                    Section("Aktuelle Freigabe") {
                        LabeledContent("Agent") { Text(grant.agentName) }
                        LabeledContent("Quellen") { Text("\(grant.allowedSourceIDs.count)") }
                        LabeledContent("Notizen") {
                            Text(grant.includesHighlights ? "eingeschlossen" : "ausgenommen")
                        }
                        LabeledContent("Läuft ab") {
                            Text(grant.expiresAt.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }

                Section {
                    if let entries = access?.auditLog, !entries.isEmpty {
                        ForEach(entries.prefix(20)) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.tool.summary)
                                    if let query = entry.query {
                                        Text(query)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(entry.resultCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(entry.at.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Noch nichts abgefragt.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Was gelesen wurde")
                } footer: {
                    Text("Ein Zugang ohne Protokoll ist kein kontrollierter Zugang.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let created = access ?? MCPAccess(store: model.store)
            access = created
            isEnabled = created.isEnabled
        }
    }

    private func authorize() {
        guard let access else { return }
        access.authorize(MCPGrant(
            agentName: agentName,
            tools: Set(MCPTool.allCases),
            allowedSourceIDs: selectedSources,
            includesHighlights: includesHighlights,
            validFor: TimeInterval(hours) * 3600
        ))
    }
}
