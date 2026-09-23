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
//  erst überhaupt ein Zugang, dann wie der Agent hereinkommt, dann worauf,
//  dann wie lange, und darunter, was tatsächlich gelesen wurde.
//
//  Die Anfragen beantwortet nicht dieses Fenster, sondern der Prozess, den
//  der Agent mit `--mcp` startet. Er liest Schalter und Freigabe aus den
//  Einstellungen und schreibt dorthin sein Protokoll. Deshalb liest die
//  Ansicht regelmässig nach, solange sie offen ist.
//

import AppKit
import SwiftUI
import PodcastAIKit

struct MCPSettingsView: View {

    /// Derselbe Zugang wie im Rest der App, nicht einer pro Fenster.
    let access: MCPAccess

    @Environment(AppModel.self) private var model
    @State private var isEnabled = false
    @State private var agentName = ""
    @State private var selectedSources: Set<SourceID> = []
    @State private var includesHighlights = false
    @State private var hours = 1
    @State private var grant: MCPGrant?
    @State private var entries: [MCPAccess.AuditEntry] = []
    @State private var copied: CopiedText?

    /// Was zuletzt in die Zwischenablage ging, damit nur dieser Knopf
    /// „Kopiert“ zeigt.
    private enum CopiedText { case configuration, command }

    var body: some View {
        Form {
            Section {
                Toggle("Agentenzugang erlauben", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        access.isEnabled = newValue
                        reload()
                    }
            } header: {
                Text("Zugang")
            } footer: {
                Text("""
                    Nur lesend und nur auf diesem Mac. Der Agent startet PodcastAI selbst und spricht \
                    über die Standardeingabe mit ihm, einen Netzwerk-Port gibt es nicht. Es gibt kein \
                    Werkzeug, das schreibt, löscht oder Wiedergabe startet. Ausgeschaltet beantwortet \
                    PodcastAI keine Anfrage mehr, auch nicht in einer laufenden Verbindung.
                    """)
            }

            if isEnabled {
                Section {
                    Text(Self.configuration)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button(copyLabel(.configuration, idle: "Eintrag kopieren")) {
                        copy(Self.configuration, as: .configuration)
                    }
                    Text(Self.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button(copyLabel(.command, idle: "Befehl kopieren")) {
                        copy(Self.command, as: .command)
                    }
                } header: {
                    Text("Verbinden")
                } footer: {
                    Text("""
                        Den Eintrag übernimmst du in die MCP-Einstellungen deines Agenten, etwa in die \
                        Konfigurationsdatei von Claude Desktop. Agenten im Terminal bekommen stattdessen \
                        den Befehl. Der Agent startet PodcastAI dann selbst mit „\(MCPHost.argument)“, im \
                        Hintergrund ohne Fenster und ohne Symbol im Dock, und beendet es wieder, wenn er \
                        fertig ist. Die App muss dafür nicht offen sein. Liegt PodcastAI später an einem \
                        anderen Ort, braucht der Agent den neuen Eintrag. Ohne Freigabe darunter bekommt \
                        er nichts zu lesen.
                        """)
                }

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

                    Toggle("Gemerkte Stellen und gesicherte Antworten einschliessen",
                           isOn: $includesHighlights)

                    Stepper(value: $hours, in: 1...24) {
                        Text("Gültig für ^[\(hours) Stunde](inflect: true)")
                    }

                    HStack {
                        Button("Freigeben") { authorize() }
                            .disabled(agentName.isEmpty || selectedSources.isEmpty)
                        Button("Zurückziehen", role: .destructive) {
                            access.revoke()
                            reload()
                        }
                        .disabled(grant == nil)
                    }
                }

                if let grant {
                    Section("Aktuelle Freigabe") {
                        LabeledContent("Agent") { Text(grant.agentName) }
                        LabeledContent("Podcasts") {
                            Text(grant.allowedSourceIDs.count, format: .number)
                        }
                        LabeledContent("Notizen") {
                            Text(grant.includesHighlights ? "eingeschlossen" : "ausgenommen")
                        }
                        LabeledContent(grant.expiresAt > Date() ? "Läuft ab" : "Abgelaufen") {
                            Text(grant.expiresAt.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }

                Section {
                    if entries.isEmpty {
                        Text("Noch nichts abgefragt.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries.prefix(20)) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.tool.title)
                                    if let query = entry.query {
                                        Text(query)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(entry.resultCount, format: .number)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(entry.at.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
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
            isEnabled = access.isEnabled
            // Der Agent schreibt aus einem eigenen Prozess ins Protokoll.
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Nur zuweisen, was sich geändert hat, sonst baut sich die Seite
    /// bei jedem Nachlesen neu auf.
    private func reload() {
        let freshGrant = access.grant
        if freshGrant != grant { grant = freshGrant }
        let freshEntries = access.auditLog
        if freshEntries != entries { entries = freshEntries }
    }

    private func authorize() {
        access.authorize(MCPGrant(
            agentName: agentName,
            tools: Set(MCPTool.allCases),
            allowedSourceIDs: selectedSources,
            includesHighlights: includesHighlights,
            validFor: TimeInterval(hours) * 3600
        ))
        reload()
    }

    /// Als `LocalizedStringKey` getippt, damit beide Beschriftungen im
    /// Katalog landen.
    private func copyLabel(_ kind: CopiedText, idle: LocalizedStringKey) -> LocalizedStringKey {
        copied == kind ? "Kopiert" : idle
    }

    private func copy(_ text: String, as kind: CopiedText) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == kind { copied = nil }
        }
    }

    /// Wo dieses Programm liegt. Aus dem Bundle gelesen, nicht angenommen:
    /// die App muss nicht unter /Programme liegen.
    private static var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/PodcastAI.app/Contents/MacOS/PodcastAI"
    }

    /// Die Befehlszeile für Agenten, die einen Befehl statt eines Eintrags
    /// erwarten. Der Pfad steht in einfachen Anführungszeichen, sobald er
    /// etwas enthält, das die Shell anders lesen würde, etwa ein Leerzeichen.
    private static var command: String {
        "\(shellQuoted(executablePath)) \(MCPHost.argument)"
    }

    private static func shellQuoted(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        guard path.unicodeScalars.contains(where: { !plain.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Der Eintrag im Format, das die meisten MCP-Programme lesen.
    private static var configuration: String {
        let entry: [String: Any] = [
            "mcpServers": [
                "podcastai": ["command": executablePath, "args": [MCPHost.argument]],
            ],
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(executablePath) \(MCPHost.argument)"
        }
        return text
    }
}
