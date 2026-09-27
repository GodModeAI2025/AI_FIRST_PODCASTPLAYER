//
//  MCPHost.swift
//  PodcastAI (macOS)
//
//  Der Prozess, den ein Agent startet: `PodcastAI --mcp`.
//
//  Hier stehen nur Prozess und Transport. Was auf eine Anfrage geantwortet
//  wird, entscheiden `MCPServer` und `MCPAccess` im Paket PodcastAIKit, wo
//  `swift test` sie gegen echte Anfragen prüft.
//
//  Es gibt keinen Netzwerk-Port und kein Lauschen im LAN. Der einzige Weg
//  herein ist die Standardeingabe des Prozesses, den der Agent selbst
//  gestartet hat.
//

import Foundation
import SwiftData
import PodcastAIKit

/// Öffnet die Mediathek ohne iCloud-Abgleich und beantwortet Zeilen von der
/// Standardeingabe, bis sie endet.
///
/// Kein Werkzeug speichert etwas. Ob etwas herausgeht, entscheiden Schalter
/// und Freigabe aus den Einstellungen der App, bei jeder Anfrage neu.
///
/// Die App-Sandbox steht dem nicht im Weg. Der Agent startet dasselbe
/// signierte Programm wie die App, also mit derselben Sandbox und demselben
/// Container: dieselbe Datenbank, dieselben Einstellungen, dasselbe
/// Protokoll. Standardein- und -ausgabe bringt der Prozess vom Agenten mit,
/// und die Sandbox lässt ihm diese geerbten Kanäle. Nicht starten kann das
/// Programm nur ein Agent, der selbst in einer Sandbox läuft. Sein
/// Kindprozess müsste dessen Sandbox erben und dürfte keine eigene
/// mitbringen. Claude Desktop, Claude Code und das Terminal laufen ohne.
@MainActor
enum MCPHost {

    static let argument = MCPSetup.argument

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
            // Claude Desktop schreibt diese Zeile in seine Protokolldatei.
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
/// Der ganze Transport. Kein Port, kein Lauschen. Die einzige Art, hier
/// hineinzukommen, ist, den Prozess zu starten und ihm zu schreiben.
@MainActor
final class MCPStdioTransport {

    private let server: MCPServer
    private var isRunning = false

    init(server: MCPServer) {
        self.server = server
    }

    /// Liest bis zum Ende der Eingabe.
    ///
    /// Eine Zeile, eine Anfrage. Eine unlesbare Zeile beendet nicht den
    /// Prozess: der Fehler geht zurück, und die nächste Zeile wird gelesen.
    func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var reader = LineReader(handle: input)
        while let line = reader.nextLine() {
            let response: Data?
            switch line {
            case .text(let data):
                guard !data.isEmpty else { continue }
                response = await server.handle(data)
            case .overlong:
                // Ohne Antwort wartete der Agent bis zu seiner Zeitgrenze.
                response = server.overlongLineResponse()
            }
            if let response {
                try? output.write(contentsOf: response + Data([0x0A]))
            }
        }
    }
}

/// Zerlegt einen Strom in Zeilen.
///
/// Mit Obergrenze: eine Zeile ohne Zeilenende ist sonst eine Einladung, den
/// Speicher zu füllen. Derselbe Fehler wie bei einem Download ohne Grenze,
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

    enum Line {
        /// Eine Zeile ohne Zeilenende.
        case text(Data)
        /// Eine Zeile über `maximumLineBytes`. Sie wird bis zu ihrem Ende
        /// verworfen, die nächste Zeile gilt wieder.
        case overlong
    }

    let handle: FileHandle
    private var buffer = Data()
    private var finished = false
    /// Gesetzt, solange der Rest einer überlangen Zeile weggeworfen wird.
    private var skippingRest = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Die nächste Zeile, oder `nil` am Ende der Eingabe.
    mutating func nextLine() -> Line? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if skippingRest {
                    // Das Ende der überlangen Zeile. Gemeldet ist sie schon.
                    skippingRest = false
                    continue
                }
                return .text(line)
            }
            if finished {
                let rest = Data(buffer)
                buffer.removeAll(keepingCapacity: false)
                if skippingRest || rest.isEmpty { return nil }
                return .text(rest)
            }
            if buffer.count > Self.maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                if !skippingRest {
                    skippingRest = true
                    return .overlong
                }
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
