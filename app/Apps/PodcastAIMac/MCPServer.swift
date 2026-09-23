//
//  MCPServer.swift
//  PodcastAI (macOS)
//
//  Der Zugang, der bisher fehlte.
//
//  `MCPAccess` war da: Werkzeuge, Freigaben mit Ablauf, Scope, Protokoll.
//  Was fehlte, war alles dazwischen — kein JSON-RPC, keine stdio-Schleife,
//  kein `tools/list`. Eine Werkzeugklasse ohne Server ist kein Zugang, und
//  Kapitel 17 stand damit im Quelltext, aber nicht in der App.
//
//  Zwei Teile, bewusst getrennt:
//
//  * **`MCPServer`** ist eine reine Funktion von Anfrage nach Antwort:
//    `Data` rein, `Data` raus. Kein Dateihandle, keine Schleife, kein
//    Zustand außer dem Zugang selbst. Genau deshalb lässt sich das
//    Protokoll gegen echte Anfragen prüfen, ohne einen Prozess zu starten.
//  * **`MCPStdioTransport`** liest Zeilen und schreibt Zeilen. Mehr nicht.
//
//  Was hier **nicht** steht, ist so wichtig wie das, was hier steht: es gibt
//  keinen Netzwerk-Port und kein Lauschen im LAN. Der einzige Weg herein ist
//  die Standardeingabe des Prozesses, den der Nutzer selbst gestartet hat.
//
//  Gestartet wird dieser Prozess mit `PodcastAI --mcp` (siehe `MCPHost`).
//  Der Agent trägt das Programm als MCP-Server ein und startet es selbst.
//

import Foundation
import SwiftData
import PodcastAIKit

/// JSON-RPC 2.0 über MCP, so viel wie gebraucht wird.
@MainActor
public final class MCPServer {

    /// Die Protokollfassung, gegen die geantwortet wird.
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "podcastai"

    private let access: MCPAccess

    public init(access: MCPAccess) {
        self.access = access
    }

    /// Fehlercodes nach JSON-RPC 2.0. Sie stehen hier und nicht als Zahlen
    /// im Code, damit `-32602` nicht irgendwann `-32601` wird.
    public enum ErrorCode: Int {
        case parse = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        /// Kein JSON-RPC-Code, sondern unserer: der Zugang ist aus oder die
        /// Freigabe deckt das Werkzeug nicht ab.
        case notAuthorized = -32000
    }

    /// Beantwortet eine einzelne Anfrage.
    ///
    /// `nil` heißt: nichts zurückschicken. Das ist kein Fehlerfall, sondern
    /// die vorgeschriebene Antwort auf eine Benachrichtigung — eine Anfrage
    /// ohne `id` erwartet keine.
    public func handle(_ data: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let request = object as? [String: Any] else {
            return encode(failure: .parse, message: String(localized: "Kein gültiges JSON."), id: nil)
        }
        guard let method = request["method"] as? String else {
            return encode(failure: .invalidRequest,
                          message: String(localized: "Kein `method`.",
                                          comment: "`method` ist ein JSON-RPC-Feld, nicht übersetzen."),
                          id: identifier(of: request))
        }
        let id = identifier(of: request)
        let params = request["params"] as? [String: Any] ?? [:]

        // Benachrichtigungen bekommen keine Antwort — auch keine Fehlermeldung.
        guard id != nil else { return nil }

        switch method {
        case "initialize":
            return encode(result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": "1.0.0"],
            ], id: id)

        case "ping":
            return encode(result: [:], id: id)

        case "tools/list":
            return encode(result: ["tools": toolDescriptions()], id: id)

        case "tools/call":
            return await handleCall(params: params, id: id)

        default:
            return encode(failure: .methodNotFound,
                          message: String(localized: "Unbekannte Methode „\(method)“."), id: id)
        }
    }

    // MARK: - Werkzeuge

    private func handleCall(params: [String: Any], id: Any?) async -> Data? {
        guard let name = params["name"] as? String else {
            return encode(failure: .invalidParams,
                          message: String(localized: "Kein `name`.",
                                          comment: "`name` ist ein MCP-Feld, nicht übersetzen."),
                          id: id)
        }
        guard let tool = MCPTool(rawValue: name) else {
            // Absichtlich derselbe Text für „gibt es nicht“ und „darfst du
            // nicht“ wäre bequem, aber falsch: ein Tippfehler soll als
            // Tippfehler erkennbar sein.
            return encode(failure: .methodNotFound,
                          message: String(localized: "Unbekanntes Werkzeug „\(name)“."), id: id)
        }
        // Schalter und Freigabe werden bei jeder Anfrage frisch gelesen:
        // was in den Einstellungen der App zurückgezogen wird, gilt sofort,
        // auch in einer laufenden Verbindung.
        guard access.isEnabled else {
            return encode(failure: .notAuthorized,
                          message: String(localized: "Der Agentenzugang ist in PodcastAI ausgeschaltet."),
                          id: id)
        }
        guard let grant = access.grant, grant.permits(tool) else {
            return encode(failure: .notAuthorized,
                          message: String(localized: """
                              Für „\(name)“ liegt keine gültige Freigabe vor. Freigeben lässt sie sich \
                              in PodcastAI unter Einstellungen › Agenten.
                              """), id: id)
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch tool {
        case .listInterests:
            return encode(content: await access.listInterests(), id: id)

        case .searchEvidence:
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return encode(failure: .invalidParams,
                              message: String(localized: "`query` fehlt oder ist leer.",
                                              comment: "`query` ist ein Werkzeugargument, nicht übersetzen."),
                              id: id)
            }
            let limit = Self.clampedLimit(arguments["limit"])
            return encode(content: await access.searchEvidence(query, limit: limit), id: id)

        case .getEvidence:
            guard let identifier = arguments["id"] as? String, !identifier.isEmpty else {
                return encode(failure: .invalidParams,
                              message: String(localized: "`id` fehlt.",
                                              comment: "`id` ist ein Werkzeugargument, nicht übersetzen."),
                              id: id)
            }
            guard let summary = await access.getEvidence(identifier) else {
                // Nicht gefunden und nicht freigegeben sehen von außen
                // gleich aus. Sonst ließe sich über die Fehlermeldung
                // herausfinden, welche Kennungen es gibt.
                return encode(failure: .notAuthorized,
                              message: String(localized: "Zu dieser Kennung liegt nichts Freigegebenes vor."),
                              id: id)
            }
            return encode(content: summary, id: id)

        case .listHighlights:
            return encode(content: await access.listHighlights(limit: Self.clampedLimit(arguments["limit"])),
                          id: id)

        case .listTrails:
            return encode(content: await access.listTrails(limit: Self.clampedLimit(arguments["limit"])),
                          id: id)
        }
    }

    /// Eine Obergrenze, die der Aufrufer nicht aushebeln kann.
    ///
    /// Ohne sie bestimmt der Agent, wie viel er auf einmal bekommt — und
    /// „alles“ ist kein Scope.
    static func clampedLimit(_ raw: Any?, maximum: Int = 100) -> Int {
        let fallback = 20
        // `true` ist keine Zahl, auch wenn `JSONSerialization` es als
        // `NSNumber` liefert. Es als 1 zu lesen wäre eine stille
        // Fehldeutung — der Aufrufer bekäme ein Ergebnis auf eine Frage,
        // die er nicht gestellt hat.
        if raw is Bool { return fallback }

        let requested: Int
        switch raw {
        case let value as Int:
            requested = value
        case let value as Double:
            // Unendlich und `NaN` nach `Int` zu wandeln ist in Swift kein
            // großer Wert, sondern ein Absturz — und `1e30` ebenso.
            // Deshalb wird **vor** der Umwandlung abgeschnitten, nicht danach.
            guard value.isFinite else { return fallback }
            if value >= Double(maximum) { return maximum }
            if value <= 1 { return 1 }
            requested = Int(value.rounded(.towardZero))
        default:
            return fallback
        }
        return min(max(1, requested), maximum)
    }

    private func toolDescriptions() -> [[String: Any]] {
        MCPTool.allCases.map { tool in
            [
                "name": tool.rawValue,
                "description": tool.summary,
                "inputSchema": Self.schema(for: tool),
                // Steht ausdrücklich dabei: keines dieser Werkzeuge ändert
                // etwas. Es gibt auch keines, das es könnte.
                "annotations": ["readOnlyHint": true, "destructiveHint": false],
            ]
        }
    }

    static func schema(for tool: MCPTool) -> [String: Any] {
        switch tool {
        case .searchEvidence:
            return [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Wonach gesucht wird."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                ],
                "required": ["query"],
            ]
        case .getEvidence:
            return [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
            ]
        case .listInterests:
            return ["type": "object", "properties": [:]]
        case .listHighlights, .listTrails:
            return [
                "type": "object",
                "properties": ["limit": ["type": "integer", "minimum": 1, "maximum": 100]],
            ]
        }
    }

    // MARK: - Kodieren

    /// Die `id` einer Anfrage, in der Form, in der sie kam.
    ///
    /// JSON-RPC erlaubt Zahl **oder** Zeichenkette, und die Antwort muss
    /// dieselbe Form tragen. Sie in String umzuwandeln wäre bequem und
    /// würde jeden Aufrufer verwirren, der Zahlen benutzt.
    private func identifier(of request: [String: Any]) -> Any? {
        guard let value = request["id"], !(value is NSNull) else { return nil }
        return value
    }

    private func encode(result: [String: Any], id: Any?) -> Data? {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { payload["id"] = id }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Ein Werkzeugergebnis. MCP verlangt `content` als Liste von Blöcken;
    /// strukturierte Daten gehen zusätzlich als `structuredContent` mit,
    /// damit ein Agent sie nicht aus Text zurückgewinnen muss.
    private func encode<Value: Encodable>(content: Value, id: Any?) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let json = try? encoder.encode(content),
              let text = String(data: json, encoding: .utf8) else {
            return encode(failure: .internalError,
                          message: String(localized: "Das Ergebnis ließ sich nicht darstellen."),
                          id: id)
        }
        let structured = (try? JSONSerialization.jsonObject(with: json)) ?? [:]
        return encode(result: [
            "content": [["type": "text", "text": text]],
            "structuredContent": structured,
            "isError": false,
        ], id: id)
    }

    private func encode(failure code: ErrorCode, message: String, id: Any?) -> Data? {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code.rawValue, "message": message],
        ]
        // Auf eine Anfrage ohne brauchbare `id` antwortet JSON-RPC mit `null`.
        payload["id"] = id ?? NSNull()
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

/// Der Prozess, den ein Agent startet: `PodcastAI --mcp`.
///
/// Er öffnet die Mediathek ohne iCloud-Abgleich und ohne Aufräumen. Er liest
/// nur, und die App kann zur selben Zeit laufen: zwei Prozesse, die
/// dieselbe Datei mit iCloud abgleichen, darf es nicht geben, und ein
/// unpassender Speicher wird hier nicht beiseitegelegt, sondern gemeldet.
/// Ob etwas herausgeht, entscheiden Schalter und Freigabe aus den
/// Einstellungen der App, bei jeder Anfrage neu.
///
/// Die App-Sandbox steht dem nicht im Weg. Der Agent startet dasselbe
/// signierte Programm wie die App, also mit derselben Sandbox und demselben
/// Container: dieselbe Datenbank, dieselben Einstellungen, dasselbe
/// Protokoll. Standardein- und -ausgabe bringt der Prozess vom Agenten mit,
/// und die Sandbox lässt ihm diese geerbten Kanäle. Nicht starten kann das
/// Programm nur ein Agent, der selbst in einer Sandbox läuft. Sein
/// Kindprozess müsste dessen Sandbox erben und dürfte keine eigene
/// mitbringen.
@MainActor
enum MCPHost {

    static let argument = "--mcp"

    static var isRequested: Bool {
        CommandLine.arguments.dropFirst().contains(argument)
    }

    /// Kehrt nicht zurück. Am Ende der Eingabe endet der Prozess.
    ///
    /// `dispatchMain` statt einer Ereignisschleife von AppKit: es gibt kein
    /// Fenster, und die Hauptwarteschlange ist alles, was der Leser braucht.
    static func runAndExit() -> Never {
        Task {
            exit(await run())
        }
        dispatchMain()
    }

    private static func run() async -> Int32 {
        let container: ModelContainer
        do {
            container = try LibraryStore.openPersistentContainer(sync: false)
        } catch {
            report(String(localized:
                "Die Datenbank von PodcastAI ließ sich nicht öffnen. \(error.localizedDescription)"))
            return 1
        }
        let access = MCPAccess(store: LibraryStore.make(container: container))
        if !access.isEnabled {
            // Der Prozess läuft trotzdem weiter: wer den Zugang danach in
            // den Einstellungen einschaltet, muss den Agenten nicht neu starten.
            report(String(localized: """
                Der Agentenzugang ist ausgeschaltet. Einschalten lässt er sich in PodcastAI \
                unter Einstellungen › Agenten.
                """))
        }
        await MCPStdioTransport(server: MCPServer(access: access)).run()
        return 0
    }

    /// Hinweise gehen auf die Fehlerausgabe. Die Standardausgabe gehört dem
    /// Protokoll, jede andere Zeile dort brächte den Agenten durcheinander.
    private static func report(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("PodcastAI: \(message)\n".utf8))
    }
}

/// Zeilenweises JSON über die Standardein- und -ausgabe.
///
/// Der ganze Transport. Kein Port, kein Lauschen — die einzige Art, hier
/// hineinzukommen, ist, den Prozess zu starten und ihm zu schreiben.
@MainActor
public final class MCPStdioTransport {

    private let server: MCPServer
    private var isRunning = false

    public init(server: MCPServer) {
        self.server = server
    }

    /// Liest bis zum Ende der Eingabe.
    ///
    /// Eine Zeile, eine Anfrage. Eine unlesbare Zeile beendet nicht den
    /// Prozess: der Fehler geht zurück, und die nächste Zeile wird gelesen.
    public func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var reader = LineReader(handle: input)
        while let line = reader.nextLine() {
            guard !line.isEmpty else { continue }
            if let response = await server.handle(line) {
                try? output.write(contentsOf: response + Data([0x0A]))
            }
        }
    }
}

/// Zerlegt einen Strom in Zeilen.
///
/// Mit Obergrenze: eine Zeile ohne Zeilenende ist sonst eine Einladung, den
/// Speicher zu füllen — derselbe Fehler wie bei einem Download ohne Grenze,
/// nur an einer anderen Stelle.
///
/// Bewusst blockierend und kein `AsyncSequence`: dieser Leser läuft in einem
/// Prozess, dessen einzige Aufgabe das Lesen ist. Ihn asynchron zu bauen
/// hiesse, Nebenläufigkeit dort einzuführen, wo es nichts nebenher zu tun gibt.
/// Blockierend heißt nur: warten, bis überhaupt etwas da ist. Eine Zeile
/// wird beantwortet, sobald sie angekommen ist.
struct LineReader {

    static let maximumLineBytes = 4 * 1024 * 1024
    static let chunkBytes = 64 * 1024

    let handle: FileHandle
    private var buffer = Data()
    private var finished = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Die nächste Zeile ohne Zeilenende, oder `nil` am Ende der Eingabe.
    mutating func nextLine() -> Data? {
        if finished && buffer.isEmpty { return nil }

        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            if finished {
                let rest = Data(buffer)
                buffer.removeAll(keepingCapacity: false)
                return rest.isEmpty ? nil : rest
            }
            if buffer.count > Self.maximumLineBytes {
                // Die überlange Zeile wird verworfen, nicht der Prozess
                // beendet. Eine leere Zeile überspringt der Aufrufer.
                buffer.removeAll(keepingCapacity: false)
                return Data()
            }
            guard let chunk = readAvailable() else {
                finished = true
                continue
            }
            buffer.append(chunk)
        }
    }

    /// Was gerade in der Eingabe liegt, höchstens `chunkBytes`. Wartet nur,
    /// solange noch gar nichts da ist. `nil` am Ende der Eingabe oder bei
    /// einem Lesefehler.
    ///
    /// Bewusst `read(2)` und nicht `FileHandle.read(upToCount:)`. Das kehrt
    /// an einer Pipe erst zurück, wenn die ganze Menge beisammen ist oder die
    /// Eingabe endet. Ein Agent schickt `initialize` und wartet auf die
    /// Antwort, bevor er weiterschreibt. Mit dem alten Aufruf warteten beide
    /// aufeinander, und keine einzige Antwort kam an.
    private func readAvailable() -> Data? {
        let descriptor = handle.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: Self.chunkBytes)
        while true {
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 { return Data(bytes[0..<count]) }
            if count == 0 { return nil }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                // Manche Aufrufer reichen die Pipe nicht blockierend weiter.
                // Dann wird gewartet, bis etwas kommt, statt das als Ende
                // der Eingabe zu lesen.
                var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&request, 1, -1)
                continue
            default:
                return nil
            }
        }
    }
}
