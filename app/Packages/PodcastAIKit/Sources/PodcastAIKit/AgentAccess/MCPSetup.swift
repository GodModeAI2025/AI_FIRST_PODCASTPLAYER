//
//  MCPSetup.swift
//  PodcastAIKit
//
//  Die Texte zum Kopieren, mit denen ein Agent PodcastAI einträgt.
//
//  Bis 0.13 gab es einen JSON-Block mit eigener Hülle „mcpServers“ und
//  den nackten Programmpfad. In eine vorhandene Datei von Claude Desktop
//  eingefügt, ergab der Block ungültiges JSON, und der Pfad allein tat im
//  Terminal nichts, außer still auf Eingaben zu warten. Hier stehen die
//  Texte so, wie sie an ihrem Ziel gebraucht werden.
//

#if os(macOS)
import Foundation

public enum MCPSetup {

    /// Unter diesem Namen trägt ein Agent den Server ein.
    public static let serverKey = "podcastai"
    /// Das Argument, mit dem der Agent PodcastAI als Server startet.
    public static let argument = "--mcp"
    /// Wo Claude Desktop seine MCP-Server liest. Mit Tilde, so wie man den
    /// Pfad im Finder unter „Gehe zu Ordner“ eintippt.
    public static let claudeDesktopFolder = "~/Library/Application Support/Claude"
    public static let claudeDesktopFile = "claude_desktop_config.json"
    public static var claudeDesktopConfigPath: String { "\(claudeDesktopFolder)/\(claudeDesktopFile)" }
    /// Hier schreibt Claude Desktop hin, was der Server auf die
    /// Fehlerausgabe meldet, etwa dass der Zugang ausgeschaltet ist.
    public static var claudeDesktopLogPath: String { "~/Library/Logs/Claude/mcp-server-\(serverKey).log" }
    /// Zeigt in Claude Code, ob die Verbindung steht.
    public static let claudeCodeCheckCommand = "claude mcp list"

    /// Der Eintrag für den Block „mcpServers“ in claude_desktop_config.json.
    ///
    /// Ohne äußere Klammern, damit er neben andere Server passt.
    public static func claudeDesktopEntry(executablePath: String) -> String {
        """
        "\(serverKey)": {
          "command": \(jsonString(executablePath)),
          "args": ["\(argument)"]
        }
        """
    }

    /// Eine ganze Datei, für eine neue oder leere claude_desktop_config.json.
    public static func claudeDesktopConfiguration(executablePath: String) -> String {
        let entry = claudeDesktopEntry(executablePath: executablePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
        return "{\n  \"mcpServers\": {\n\(entry)\n  }\n}"
    }

    /// Der Befehl für Claude Code im Terminal. `--scope user` trägt den
    /// Server für alle Projekte ein. Ohne gälte er nur im Ordner, in dem
    /// der Befehl lief.
    public static func claudeCodeCommand(executablePath: String) -> String {
        "claude mcp add --scope user \(serverKey) -- \(shellQuoted(executablePath)) \(argument)"
    }

    /// Der Pfad in einfachen Anführungszeichen, sobald er etwas enthält,
    /// das die Shell anders lesen würde, etwa ein Leerzeichen.
    public static func shellQuoted(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        guard path.unicodeScalars.contains(where: { !plain.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Ob die App aus einem vorläufigen Ordner läuft. macOS startet eine
    /// frisch geladene App, die noch nicht verschoben wurde, an einem
    /// zufälligen Ort, und der Eintrag zeigte beim nächsten Start ins Leere.
    public static func isTemporaryLocation(_ executablePath: String) -> Bool {
        executablePath.contains("/AppTranslocation/")
    }

    /// Eine Zeichenkette als JSON, mit Anführungszeichen und Escapes.
    static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let json = String(data: data, encoding: .utf8) else {
            return "\"\(text)\""
        }
        return json
    }
}
#endif
