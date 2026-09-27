//
//  MCPSettingsView.swift
//  PodcastAI (macOS)
//
//  Der Agentenzugang als Anleitung in drei Schritten: einschalten, den
//  Agenten eintragen, Podcasts freigeben. Darunter die geltende Freigabe
//  und was gelesen wurde.
//
//  Bis 0.13 stand der Eintrag für den Agenten erst da, wenn der Schalter an
//  war, und nirgends, wohin er gehört. Jetzt steht alles auf einmal da, in
//  der Reihenfolge, in der man es braucht. Kopieren gibt nichts frei, das
//  tut erst „Freigeben“.
//
//  Die Anfragen beantwortet nicht dieses Fenster, sondern der Prozess, den
//  der Agent mit `--mcp` startet. Er liest Schalter und Freigabe aus den
//  Einstellungen und schreibt dorthin sein Protokoll. Deshalb liest die
//  Ansicht alle zwei Sekunden nach, solange sie offen ist, und merkt dabei
//  auch, wenn die Freigabe abläuft.
//

import AppKit
import SwiftUI
import PodcastAIKit

struct MCPSettingsView: View {

    /// Derselbe Zugang wie im Rest der App, nicht einer pro Fenster.
    let access: MCPAccess

    @Environment(AppModel.self) private var model
    @State private var isEnabled = false
    @State private var selectedSources: Set<SourceID> = []
    @State private var includesHighlights = false
    @State private var hours = 1
    /// `nil` heißt: jeder Agent auf diesem Mac.
    @State private var client: String?
    @State private var grant: MCPGrant?
    @State private var grantExpired = false
    @State private var entries: [MCPAccess.AuditEntry] = []
    @State private var clients: [MCPAccess.ClientRecord] = []
    @State private var copied: CopiedText?

    /// Was zuletzt in die Zwischenablage ging, damit nur dieser Knopf
    /// „Kopiert“ zeigt.
    private enum CopiedText { case desktopPath, desktopEntry, desktopFile, codeCommand }

    var body: some View {
        Form {
            Section {
                Text("""
                    MCP ist ein offenes Verfahren, über das KI-Programme wie Claude Desktop oder Claude Code \
                    andere Programme als Werkzeug nutzen. Mit deiner Freigabe liest ein solcher Agent hier \
                    Stellen aus Transkripten mit Podcast, Folge und Zeitmarke, deine gefolgten Tags und auf \
                    Wunsch deine gemerkten Stellen und gesicherten Antworten. Ändern, löschen oder abspielen \
                    kann er nichts.
                    """)
                Text("In drei Schritten: Zugang einschalten, Agent eintragen, Podcasts freigeben.")
                    .foregroundStyle(.secondary)
            }

            switchSection
            claudeDesktopSection
            claudeCodeSection
            grantSection
            if let grant {
                currentGrantSection(grant)
            }
            logSection
        }
        .formStyle(.grouped)
        .task {
            isEnabled = access.isEnabled
            reload()
            adoptCurrentGrant()
            // Der Agent schreibt aus einem eigenen Prozess ins Protokoll.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                reload()
            }
        }
    }

    // MARK: - Schritt 1

    private var switchSection: some View {
        Section {
            Toggle("Agentenzugang erlauben", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    guard access.isEnabled != newValue else { return }
                    access.isEnabled = newValue
                    reload()
                }
        } header: {
            Text("1. Zugang einschalten")
        } footer: {
            Text("""
                Der Agent startet PodcastAI selbst, im Hintergrund ohne Fenster, und spricht nur über die \
                Standardeingabe mit ihm. Einen Netzwerk-Port gibt es nicht, und die App muss dafür nicht \
                offen sein. Ist der Schalter aus, sieht der Agent die Werkzeuge noch, bekommt aber auf jede \
                Anfrage eine Absage, auch in einer laufenden Verbindung. Ausschalten zieht auch die \
                Freigabe zurück.
                """)
        }
    }

    // MARK: - Schritt 2

    private var claudeDesktopSection: some View {
        Section {
            Text("""
                Öffne die Datei claude_desktop_config.json. In Claude Desktop führt Einstellungen › Entwickler \
                dorthin, im Finder „Gehe zu Ordner“ (⇧⌘G) mit diesem Pfad:
                """)
            copyableBlock(MCPSetup.claudeDesktopConfigPath)
            Button(copyLabel(.desktopPath, idle: "Pfad kopieren")) {
                copy(MCPSetup.claudeDesktopConfigPath, as: .desktopPath)
            }
            Text("""
                Setze den Eintrag in den Block „mcpServers“, zwischen dessen geschweifte Klammern. Steht dort \
                schon ein Server, trennt ein Komma die beiden. Ist die Datei leer oder fehlt sie, nimm den Text \
                hinter „Ganze Datei kopieren“. Danach Claude Desktop mit ⌘Q beenden und neu öffnen.
                """)
            copyableBlock(desktopEntry)
            HStack {
                Button(copyLabel(.desktopEntry, idle: "Eintrag kopieren")) {
                    copy(desktopEntry, as: .desktopEntry)
                }
                Button(copyLabel(.desktopFile, idle: "Ganze Datei kopieren")) {
                    copy(MCPSetup.claudeDesktopConfiguration(executablePath: Self.executablePath),
                         as: .desktopFile)
                }
            }
        } header: {
            Text("2. Agent eintragen: Claude Desktop")
        } footer: {
            Text("Meldungen von PodcastAI schreibt Claude Desktop in die Datei \(MCPSetup.claudeDesktopLogPath).")
        }
    }

    private var claudeCodeSection: some View {
        Section {
            Text("""
                Füge den Befehl im Terminal ein. Er trägt PodcastAI für alle deine Projekte ein. Danach \
                zeigt „\(MCPSetup.claudeCodeCheckCommand)“, ob die Verbindung steht.
                """)
            copyableBlock(codeCommand)
            Button(copyLabel(.codeCommand, idle: "Befehl kopieren")) {
                copy(codeCommand, as: .codeCommand)
            }
            if MCPSetup.isTemporaryLocation(Self.executablePath) {
                Label {
                    Text("""
                        PodcastAI läuft gerade aus einem vorläufigen Ordner. Zieh die App in den Ordner \
                        Programme und öffne sie von dort, sonst zeigen Eintrag und Befehl beim nächsten \
                        Start ins Leere.
                        """)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("2. Agent eintragen: Claude Code")
        } footer: {
            Text("""
                Eintrag und Befehl enthalten den Ort dieser App. Liegt PodcastAI später woanders, trage \
                den Agenten neu ein.
                """)
        }
    }

    // MARK: - Schritt 3

    private var grantSection: some View {
        Section {
            if model.sources.isEmpty {
                Text("Noch keine Podcasts abonniert.")
                    .foregroundStyle(.secondary)
            }
            // Podcasts einzeln. „Alles“ ist kein Scope, und ein Knopf
            // dafür wäre eine Einladung.
            ForEach(model.sources) { source in
                Toggle(source.title, isOn: Binding(
                    get: { selectedSources.contains(source.id) },
                    set: { on in
                        if on { selectedSources.insert(source.id) } else { selectedSources.remove(source.id) }
                    }
                ))
            }

            Toggle("Gemerkte Stellen und gesicherte Antworten einschließen", isOn: $includesHighlights)

            Picker("Agent", selection: $client) {
                Text("Jeder Agent auf diesem Mac").tag(String?.none)
                ForEach(clientChoices, id: \.self) { name in
                    Text(verbatim: name).tag(Optional(name))
                }
            }

            Stepper(value: $hours, in: 1...24) {
                Text("Gültig für ^[\(hours) Stunde](inflect: true)")
            }

            HStack {
                Button("Freigeben") { authorize() }
                    .disabled(selectedSources.isEmpty)
                Button("Zurückziehen", role: .destructive) {
                    access.revoke()
                    reload()
                }
                .disabled(grant == nil)
            }
        } header: {
            Text("3. Freigeben")
        } footer: {
            if isEnabled {
                Text("""
                    Der Agent sieht nur die gewählten Podcasts, und eine neue Freigabe ersetzt die alte. Zur \
                    Wahl stehen außer „Jeder Agent“ die Agenten, die sich schon einmal verbunden haben, mit dem \
                    Namen, den sie selbst melden. Das hält einen zweiten Agenten fern, schützt aber nicht vor \
                    einem Programm, das sich mit falschem Namen meldet.
                    """)
            } else {
                Text("Freigeben geht erst, wenn der Zugang eingeschaltet ist.")
            }
        }
        .disabled(!isEnabled)
    }

    private func currentGrantSection(_ grant: MCPGrant) -> some View {
        let validHours = max(1, Int((grant.validity / 3600).rounded()))
        return Section {
            LabeledContent("Agent") {
                if let name = grant.clientName {
                    Text(verbatim: name)
                } else {
                    Text("Jeder Agent auf diesem Mac")
                }
            }
            LabeledContent("Podcasts") { Text(verbatim: podcastNames(of: grant)) }
            LabeledContent("Notizen") {
                Text(grant.includesHighlights ? "eingeschlossen" : "ausgenommen")
            }
            LabeledContent(grantExpired ? "Abgelaufen am" : "Gültig bis") {
                Text(grant.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(grantExpired ? Color.red : Color.primary)
            }
            Button("Erneuern") {
                access.authorize(grant.renewed())
                reload()
            }
        } header: {
            Text("Aktuelle Freigabe")
        } footer: {
            if grantExpired {
                Text("""
                    Seit dem Ablauf bekommt der Agent auf jede Anfrage eine Absage, die Datum und Uhrzeit des \
                    Ablaufs nennt. „Erneuern“ gibt dieselben Podcasts ab jetzt wieder für \
                    ^[\(validHours) Stunde](inflect: true) frei.
                    """)
            } else {
                Text("""
                    Danach bekommt der Agent eine Absage, die Datum und Uhrzeit des Ablaufs nennt. „Erneuern“ \
                    lässt dieselbe Freigabe ab jetzt wieder ^[\(validHours) Stunde](inflect: true) gelten.
                    """)
            }
        }
        .disabled(!isEnabled)
    }

    // MARK: - Protokoll

    private var logSection: some View {
        Section {
            if entries.isEmpty {
                Text("Noch nichts abgefragt.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(20)) { entry in
                    logRow(entry)
                }
            }
        } header: {
            Text("Was gelesen wurde")
        } footer: {
            Text("Hier stehen die letzten 20 Anfragen mit Uhrzeit, Agent und Zahl der Treffer, auch jede Absage.")
        }
    }

    private func logRow(_ entry: MCPAccess.AuditEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.tool.title)
                if let query = entry.query {
                    Text(verbatim: query)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let name = entry.client {
                        Text(verbatim: name)
                    } else {
                        Text("Agent ohne Namen")
                    }
                    if let refusal = entry.refusal {
                        Text(verbatim: "·")
                        Text(verbatim: refusal.label)
                            .foregroundStyle(refusal == .notFound ? Color.secondary : Color.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.resultCount, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(Self.timestamp(entry.at))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Zustand

    /// Nur zuweisen, was sich geändert hat, sonst baut sich die Seite
    /// bei jedem Nachlesen neu auf.
    private func reload() {
        if access.isEnabled != isEnabled { isEnabled = access.isEnabled }
        let freshGrant = access.grant
        if freshGrant != grant { grant = freshGrant }
        // Die Freigabe selbst ändert sich beim Ablauf nicht, nur die Zeit.
        let expired = freshGrant?.isExpired() ?? false
        if expired != grantExpired { grantExpired = expired }
        let freshEntries = access.auditLog
        if freshEntries != entries { entries = freshEntries }
        let freshClients = access.knownClients
        if freshClients != clients { clients = freshClients }
    }

    /// Die Auswahl zeigt beim Öffnen, was gerade gilt.
    private func adoptCurrentGrant() {
        guard let grant else { return }
        selectedSources = grant.allowedSourceIDs
        includesHighlights = grant.includesHighlights
        client = grant.clientName
        hours = min(24, max(1, Int((grant.validity / 3600).rounded())))
    }

    private func authorize() {
        access.authorize(MCPGrant(
            clientName: client,
            allowedSourceIDs: selectedSources,
            includesHighlights: includesHighlights,
            validFor: TimeInterval(hours) * 3600
        ))
        reload()
    }

    /// Agenten, die sich schon gemeldet haben, dazu der Name aus der
    /// geltenden Freigabe, falls er nicht mehr in der Liste steht.
    private var clientChoices: [String] {
        var names = clients.map(\.name)
        if let named = grant?.clientName, !names.contains(named) { names.append(named) }
        if let chosen = client, !names.contains(chosen) { names.append(chosen) }
        return names
    }

    private func podcastNames(of grant: MCPGrant) -> String {
        let titles = model.sources.filter { grant.allowedSourceIDs.contains($0.id) }.map(\.title)
        guard !titles.isEmpty else { return String(grant.allowedSourceIDs.count) }
        return titles.formatted(.list(type: .and))
    }

    private static func timestamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Kopieren

    private func copyableBlock(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Als `LocalizedStringKey` getippt, damit alle Beschriftungen im
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

    private var desktopEntry: String { MCPSetup.claudeDesktopEntry(executablePath: Self.executablePath) }
    private var codeCommand: String { MCPSetup.claudeCodeCommand(executablePath: Self.executablePath) }
}
