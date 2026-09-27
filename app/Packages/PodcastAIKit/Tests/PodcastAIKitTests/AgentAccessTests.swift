//
//  AgentAccessTests.swift
//  PodcastAIKitTests
//
//  Der Agentenzugang über MCP, von der JSON-Zeile bis zum Speicher.
//
//  Bis 0.13 lag der Server in der Mac-App, und kein Test erreichte ihn. So
//  fiel nicht auf, dass vier von fünf Werkzeugen eine Liste als
//  `structuredContent` schickten, die jeder MCP-Client verwirft. Diese
//  Tests schicken dieselben Zeilen wie ein Agent und prüfen die Antwort.
//

#if os(macOS)
import Testing
import Foundation
@testable import PodcastAIKit
import PodcastAIPersistence

@MainActor
@Suite("Agentenzugang über MCP")
struct AgentAccessTests {

    static let shared = SourceID(stable: "mcp-freigegeben")
    static let secret = SourceID(stable: "mcp-geheim")
    static let episode = EpisodeID(stable: "mcp-folge")
    static let secretEpisode = EpisodeID(stable: "mcp-geheime-folge")

    /// Ein Speicher mit einem freigegebenen und einem geheimen Podcast,
    /// eigenen Einstellungen und einem Server davor.
    struct Fixture {
        let store: LibraryStore
        let defaults: UserDefaults
        let access: MCPAccess
        let server: MCPServer
        let evidence: [Evidence]
        let secretEvidence: Evidence
    }

    static func fixture() async throws -> Fixture {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: shared, kind: .podcastRSS, title: "Arbeit und KI", language: "de"))
        try await store.upsert(source: Source(id: secret, kind: .podcastRSS, title: "Geheimer Podcast", language: "de"))
        let published = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await store.upsert(episodes: [Episode(
            id: episode, sourceID: shared, title: "Datenschutz im Team", publishedAt: published,
            audioURL: URL(string: "https://example.org/a.mp3")!)], forSource: shared)
        _ = try await store.upsert(episodes: [Episode(
            id: secretEpisode, sourceID: secret, title: "Geheime Folge", publishedAt: published,
            audioURL: URL(string: "https://example.org/b.mp3")!)], forSource: secret)

        let lines = [
            "Viele Unternehmen testen KI-Assistenten zuerst im Kundenservice.",
            "Ein Problem ist der Datenschutz, denn Anfragen enthalten oft persönliche Daten.",
            "Modelle auf dem Gerät verarbeiten Text lokal, dadurch verlassen Daten das Telefon nicht.",
            "Kritisch bleibt die Frage, wer für Fehler eines Modells haftet.",
        ]
        let evidence = lines.enumerated().map { index, line in
            makeEvidence(line, index: index, episode: episode, source: shared)
        }
        let secretEvidence = makeEvidence(
            "Datenschutz ist im geheimen Podcast das wichtigste Thema, Modelle auf dem Gerät auch.",
            index: 0, episode: secretEpisode, source: secret)
        try await store.store(evidence: evidence + [secretEvidence])

        try await store.upsert(interest: Interest(label: "Datenschutz", kind: .topic))

        let defaults = MemoryDefaults()
        let access = MCPAccess(store: store, defaults: defaults)
        return Fixture(store: store, defaults: defaults, access: access,
                       server: MCPServer(access: access, version: "9.9"),
                       evidence: evidence, secretEvidence: secretEvidence)
    }

    static func makeEvidence(_ text: String, index: Int, episode: EpisodeID, source: SourceID) -> Evidence {
        let start = Int64(index) * 60_000
        let range = MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: start + 58_000))
        let media = MediaVersionID(stable: "media-\(episode.rawValue)")
        return Evidence(
            id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
            mediaVersionID: media, episodeID: episode, sourceID: source,
            transcriptID: TranscriptID(stable: "t-\(episode.rawValue)"), transcriptRevision: .initial,
            range: range, quotedText: text)
    }

    // MARK: - Hilfen für Anfragen

    static func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func send(_ server: MCPServer, _ object: [String: Any]) async throws -> [String: Any] {
        let reply = try #require(await server.handle(line(object)))
        // Eine Nachricht pro Zeile: in der Antwort darf kein Zeilenumbruch stehen.
        #expect(!reply.contains(0x0A))
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    static func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:],
                     id: Int = 7) async throws -> [String: Any] {
        let reply = try await send(server, [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        return try #require(reply["result"] as? [String: Any], "kein Ergebnis: \(reply)")
    }

    static func initialize(_ server: MCPServer, client: String = "claude-code",
                           version: String = "2025-11-25") async throws -> [String: Any] {
        let reply = try await send(server, [
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": ["protocolVersion": version, "capabilities": [String: Any](),
                       "clientInfo": ["name": client, "version": "2.1.0"]],
        ])
        return try #require(reply["result"] as? [String: Any])
    }

    static func text(of result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    static func grantAll(_ fixture: Fixture, notes: Bool = true, client: String? = nil,
                         issuedAt: Date = Date(), validFor: TimeInterval = 3600) {
        fixture.access.isEnabled = true
        fixture.access.authorize(MCPGrant(clientName: client, allowedSourceIDs: [shared],
                                          includesHighlights: notes, issuedAt: issuedAt, validFor: validFor))
    }

    // MARK: - Verbinden

    @Test("initialize nennt die angefragte Fassung, Version, Anleitung und merkt sich den Agenten")
    func initializeNegotiates() async throws {
        let fixture = try await Self.fixture()
        let result = try await Self.initialize(fixture.server, client: "claude-ai", version: "2025-06-18")
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "podcastai")
        #expect(info["version"] as? String == "9.9")
        #expect((result["instructions"] as? String)?.contains("listPodcasts") == true)
        #expect(fixture.server.clientName == "claude-ai")
        #expect(fixture.access.knownClients.map(\.name) == ["claude-ai"])

        let unknown = try await Self.initialize(fixture.server, version: "2099-01-01")
        #expect(unknown["protocolVersion"] as? String == MCPServer.supportedProtocolVersions.first)
    }

    @Test("tools/list: jedes Werkzeug mit Titel, Objektschema ohne Zusatzfelder und nur lesend")
    func toolListIsComplete() async throws {
        let fixture = try await Self.fixture()
        let reply = try await Self.send(fixture.server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == MCPTool.allCases.map(\.rawValue))
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            #expect(schema["properties"] is [String: Any])
            #expect(!(tool["title"] as? String ?? "").isEmpty)
            let hints = try #require(tool["annotations"] as? [String: Any])
            #expect(hints["readOnlyHint"] as? Bool == true)
            #expect(hints["destructiveHint"] as? Bool == false)
            #expect(hints["openWorldHint"] as? Bool == false)
        }
    }

    // MARK: - Ergebnisse

    @Test("Jedes Werkzeug liefert structuredContent als Objekt, auch wenn nichts gefunden wird")
    func everyResultIsAnObject() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture)
        _ = try await Self.initialize(fixture.server)
        let calls: [(String, [String: Any])] = [
            ("listPodcasts", [:]), ("listInterests", [:]),
            ("searchEvidence", ["query": "Datenschutz"]), ("searchEvidence", ["query": "Quantencomputer"]),
            ("getEvidence", ["id": fixture.evidence[1].id.rawValue]),
            ("listHighlights", [:]), ("listTrails", ["limit": 5]),
        ]
        for (name, arguments) in calls {
            let result = try await Self.call(fixture.server, name, arguments)
            #expect(result["isError"] as? Bool == false, "\(name): \(result)")
            #expect(result["structuredContent"] is [String: Any], "\(name) liefert kein Objekt")
            let text = Self.text(of: result)
            #expect(try JSONSerialization.jsonObject(with: Data(text.utf8)) is [String: Any], "\(name): \(text)")
        }
    }

    @Test("Suche: Treffer mit Podcast, Folge und Zeitmarke, nur aus freigegebenen Podcasts")
    func searchStaysInScope() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture)
        let result = try await Self.call(fixture.server, "searchEvidence", ["query": "Datenschutz"])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let hits = try #require(structured["results"] as? [[String: Any]])
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0["podcastID"] as? String == Self.shared.rawValue })
        #expect(!hits.contains { $0["id"] as? String == fixture.secretEvidence.id.rawValue })
        let first = try #require(hits.first)
        #expect(first["podcast"] as? String == "Arbeit und KI")
        #expect(first["episode"] as? String == "Datenschutz im Team")
        #expect(first["publishedAt"] is String)
        #expect(first["timecode"] as? String == "1:00")
    }

    @Test("Suche mit einer Frage in ganzen Sätzen findet die passende Stelle")
    func searchUnderstandsQuestions() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture)
        let result = try await Self.call(fixture.server, "searchEvidence", [
            "query": "Welche Aussagen gibt es zu Modellen auf dem Gerät?", "limit": 3,
        ])
        let hits = try #require((result["structuredContent"] as? [String: Any])?["results"] as? [[String: Any]])
        #expect(hits.first?["id"] as? String == fixture.evidence[2].id.rawValue)
    }

    @Test("Suche sieht Belege, die nach der ersten Suche dazukamen")
    func searchSeesNewEvidence() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture)
        let before = try await Self.call(fixture.server, "searchEvidence", ["query": "Quantencomputer"])
        let empty = (before["structuredContent"] as? [String: Any])?["results"] as? [[String: Any]]
        #expect(empty?.isEmpty == true)
        #expect(((before["structuredContent"] as? [String: Any])?["hint"] as? String)?.isEmpty == false)

        // Die App schreibt neue Belege, der Prozess des Agenten läuft weiter.
        // Ein zweiter Store auf demselben Speicher ginge hier nicht, deshalb
        // schreibt derselbe. Der Speicher merkt sich die Belege bis zur
        // nächsten Änderung; die Suche darf sich nicht darauf verlassen.
        let fresh = Self.makeEvidence("Quantencomputer werden die Verschlüsselung verändern.",
                                      index: 9, episode: Self.episode, source: Self.shared)
        try await fixture.store.store(evidence: [fresh])
        let after = try await Self.call(fixture.server, "searchEvidence", ["query": "Quantencomputer"])
        let hits = (after["structuredContent"] as? [String: Any])?["results"] as? [[String: Any]]
        #expect(hits?.first?["id"] as? String == fresh.id.rawValue)
    }

    @Test("listPodcasts nennt nur freigegebene Podcasts mit der Zahl ihrer Folgen mit Transkript")
    func podcastsAreScoped() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture)
        let result = try await Self.call(fixture.server, "listPodcasts")
        let podcasts = try #require((result["structuredContent"] as? [String: Any])?["podcasts"] as? [[String: Any]])
        #expect(podcasts.count == 1)
        #expect(podcasts.first?["title"] as? String == "Arbeit und KI")
        #expect(podcasts.first?["episodesWithTranscript"] as? Int == 1)
    }

    @Test("getEvidence: fremde und unbekannte Kennung sehen gleich aus")
    func foreignEvidenceLooksMissing() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture)
        let own = try await Self.call(fixture.server, "getEvidence", ["id": fixture.evidence[0].id.rawValue])
        #expect((own["structuredContent"] as? [String: Any])?["episode"] as? String == "Datenschutz im Team")

        let foreign = try await Self.call(fixture.server, "getEvidence", ["id": fixture.secretEvidence.id.rawValue])
        let unknown = try await Self.call(fixture.server, "getEvidence", ["id": "gibt-es-nicht"])
        #expect(foreign["isError"] as? Bool == true)
        #expect(Self.text(of: foreign) == Self.text(of: unknown))
    }

    @Test("Gemerkte Stellen und Antworten: Titel dabei, Fremdes fehlt, Antwort nur mit allen Stellen")
    func notesAreScoped() async throws {
        let fixture = try await Self.fixture()
        let own = fixture.evidence[2]
        try await fixture.store.save(highlights: [
            Highlight(evidenceID: own.id, note: "Für den Vortrag", capturedVia: .chat),
            Highlight(evidenceID: fixture.secretEvidence.id, note: "Geheim", capturedVia: .chat),
            // Aus dem Player: nur eine Kopie von Zitat und Zeitmarke.
            Highlight(evidenceID: EvidenceID(stable: "nicht-gespeichert"), note: "Aus dem Player",
                      quote: "Ein Satz aus der Folge", episodeID: Self.episode,
                      episodeTitle: "Datenschutz im Team", sourceTitle: "Arbeit und KI", positionMs: 90_000),
        ])
        try await fixture.store.save(trails: [
            KnowledgeTrail(question: "Was sagen meine Podcasts zu lokaler KI?", evidenceIDs: [own.id],
                           answerText: "Lokal verarbeitet [1].", citationNumbers: [1: own.id]),
            KnowledgeTrail(question: "Was sagt der geheime Podcast?", evidenceIDs: [fixture.secretEvidence.id],
                           answerText: "Geheimes [1].", citationNumbers: [1: fixture.secretEvidence.id]),
            KnowledgeTrail(question: "Offene Frage ohne Stellen", answerText: "Ohne Beleg."),
        ])
        Self.grantAll(fixture)

        let highlights = try #require(
            (try await Self.call(fixture.server, "listHighlights"))["structuredContent"] as? [String: Any])
        let list = try #require(highlights["highlights"] as? [[String: Any]])
        #expect(list.compactMap { $0["note"] as? String }.sorted() == ["Aus dem Player", "Für den Vortrag"])
        let fromKnowledge = try #require(list.first { $0["note"] as? String == "Für den Vortrag" })
        #expect(fromKnowledge["podcast"] as? String == "Arbeit und KI")
        #expect(fromKnowledge["evidenceID"] as? String == own.id.rawValue)
        let fromPlayer = try #require(list.first { $0["note"] as? String == "Aus dem Player" })
        #expect(fromPlayer["evidenceID"] == nil)
        #expect(fromPlayer["timecode"] as? String == "1:30")

        let trails = try #require(
            (try await Self.call(fixture.server, "listTrails"))["structuredContent"] as? [String: Any])
        let answers = try #require(trails["trails"] as? [[String: Any]])
        #expect(answers.count == 2)
        let cited = try #require(answers.first { ($0["question"] as? String)?.contains("lokaler KI") == true })
        #expect(cited["answer"] as? String == "Lokal verarbeitet [1].")
        #expect(cited["evidenceIDs"] as? [String] == [own.id.rawValue])
        let open = try #require(answers.first { ($0["question"] as? String)?.contains("ohne Stellen") == true })
        #expect(open["answer"] == nil)
    }

    // MARK: - Absagen

    @Test("Absagen kommen als Ergebnis mit isError und stehen im Protokoll")
    func refusalsAreToolErrors() async throws {
        let fixture = try await Self.fixture()
        _ = try await Self.initialize(fixture.server, client: "claude-code")

        // Aus: die Werkzeuge stehen trotzdem in der Liste, jede Anfrage bekommt eine Absage.
        let listed = try await Self.send(fixture.server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect(listed["result"] != nil)
        let off = try await Self.call(fixture.server, "searchEvidence", ["query": "Datenschutz"])
        #expect(off["isError"] as? Bool == true)
        #expect(off["structuredContent"] == nil)

        fixture.access.isEnabled = true
        let nothing = try await Self.call(fixture.server, "listInterests")
        #expect(nothing["isError"] as? Bool == true)
        #expect(Self.text(of: nothing) != Self.text(of: off))

        let expiredAt = Date().addingTimeInterval(-600)
        Self.grantAll(fixture, issuedAt: expiredAt.addingTimeInterval(-3600))
        let expired = try await Self.call(fixture.server, "listInterests")
        #expect(expired["isError"] as? Bool == true)
        #expect(Self.text(of: expired).contains(expiredAt.formatted(date: .omitted, time: .shortened)))

        Self.grantAll(fixture, notes: false)
        let excluded = try await Self.call(fixture.server, "listHighlights")
        #expect(excluded["isError"] as? Bool == true)

        Self.grantAll(fixture, client: "claude-ai")
        let other = try await Self.call(fixture.server, "listInterests")
        #expect(other["isError"] as? Bool == true)
        #expect(Self.text(of: other).contains("claude-ai"))
        #expect(Self.text(of: other).contains("claude-code"))

        let kinds = fixture.access.auditLog.compactMap(\.refusal)
        #expect(kinds == [.otherClient, .notesExcluded, .expired, .noGrant, .switchedOff])
        #expect(fixture.access.auditLog.allSatisfy { $0.client == "claude-code" })
    }

    @Test("Unbrauchbare Argumente stehen im Protokoll, lange Namen und Suchtexte gekürzt")
    func protocolKeepsEverythingShort() async throws {
        let fixture = try await Self.fixture()
        let longName = String(repeating: "n", count: 5_000)
        _ = try await Self.initialize(fixture.server, client: longName)
        #expect(fixture.server.clientName?.count == 100)
        #expect(fixture.access.knownClients.first?.name.count == 100)

        Self.grantAll(fixture)
        let missing = try await Self.call(fixture.server, "getEvidence")
        #expect(missing["isError"] as? Bool == true)
        #expect(fixture.access.auditLog.first?.refusal == .invalidArguments)

        _ = try await Self.call(fixture.server, "searchEvidence", ["query": String(repeating: "Datenschutz ", count: 500)])
        let logged = try #require(fixture.access.auditLog.first?.query)
        #expect(logged.count <= 201)
    }

    @Test("Eine Freigabe für einen Agenten gilt für ihn, und ein Erneuern behält den Umfang")
    func grantForOneClient() async throws {
        let fixture = try await Self.fixture()
        Self.grantAll(fixture, client: "claude-code", validFor: 2 * 3600)
        _ = try await Self.initialize(fixture.server, client: "claude-code")
        let allowed = try await Self.call(fixture.server, "listInterests")
        #expect(allowed["isError"] as? Bool == false)
        let interests = (allowed["structuredContent"] as? [String: Any])?["interests"] as? [String]
        #expect(interests == ["Datenschutz"])

        let grant = try #require(fixture.access.grant)
        let later = grant.issuedAt.addingTimeInterval(5 * 3600)
        let renewed = grant.renewed(at: later)
        #expect(renewed.allowedSourceIDs == grant.allowedSourceIDs)
        #expect(renewed.clientName == "claude-code")
        #expect(renewed.includesHighlights == grant.includesHighlights)
        #expect(renewed.expiresAt == later.addingTimeInterval(2 * 3600))
    }

    @Test("Protokollfehler: kaputtes JSON, Liste, unbekanntes Werkzeug, Benachrichtigung")
    func protocolErrors() async throws {
        let fixture = try await Self.fixture()
        let broken = try #require(await fixture.server.handle(Data("{kaputt".utf8)))
        let parse = try #require(try JSONSerialization.jsonObject(with: broken) as? [String: Any])
        #expect((parse["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(parse["id"] is NSNull)

        let batch = try #require(await fixture.server.handle(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)))
        let invalid = try #require(try JSONSerialization.jsonObject(with: batch) as? [String: Any])
        #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32600)

        let unknown = try await Self.send(fixture.server, [
            "jsonrpc": "2.0", "id": "a", "method": "tools/call", "params": ["name": "nichtDa"],
        ])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(unknown["id"] as? String == "a")

        let missing = try await Self.call(fixture.server, "searchEvidence", ["query": "  "])
        #expect(missing["isError"] as? Bool == true)

        let notification = await fixture.server.handle(Self.line(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        #expect(notification == nil)
    }

    // MARK: - Gespeichertes aus früheren Fassungen

    @Test("Freigaben und Protokoll aus 0.13 lesen sich weiter")
    func legacyStorage() throws {
        let legacyGrant = """
            {"agentName":"Irgendein Name","tools":["listInterests","searchEvidence"],
             "allowedSourceIDs":["\(Self.shared.rawValue)"],"includesHighlights":true,
             "issuedAt":780000000,"expiresAt":780003600}
            """
        let grant = try JSONDecoder().decode(MCPGrant.self, from: Data(legacyGrant.utf8))
        #expect(grant.clientName == nil)
        #expect(grant.admits(client: "claude-ai"))
        #expect(grant.allowedSourceIDs == [Self.shared])
        #expect(grant.validity == 3600)

        let defaults = MemoryDefaults()
        let legacyLog = """
            [{"id":"\(UUID().uuidString)","tool":"searchEvidence","query":"Datenschutz","resultCount":1,"at":780000000},
             {"id":"kaputt"},
             {"id":"\(UUID().uuidString)","tool":"listTrails","resultCount":0,"at":780000100}]
            """
        defaults.set(Data(legacyLog.utf8), forKey: "com.podcastai.mcp.audit")
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let log = MCPAccess(store: store, defaults: defaults).auditLog
        #expect(log.map(\.tool) == [.searchEvidence, .listTrails])
        #expect(log.allSatisfy { $0.client == nil && $0.refusal == nil })
    }

    // MARK: - Texte zum Kopieren

    @Test("Der Eintrag für Claude Desktop passt in einen vorhandenen Block mcpServers")
    func claudeDesktopEntryFits() throws {
        let path = "/Applications/PodcastAI.app/Contents/MacOS/PodcastAI"
        let existing = """
            {"mcpServers": {"andere": {"command": "/usr/bin/true"},
            \(MCPSetup.claudeDesktopEntry(executablePath: path))
            }, "preferences": {}}
            """
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any])
        let servers = try #require(parsed["mcpServers"] as? [String: Any])
        let entry = try #require(servers["podcastai"] as? [String: Any])
        #expect(entry["command"] as? String == path)
        #expect(entry["args"] as? [String] == ["--mcp"])

        let file = MCPSetup.claudeDesktopConfiguration(executablePath: path)
        let whole = try #require(try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
        #expect(((whole["mcpServers"] as? [String: Any])?["podcastai"] as? [String: Any])?["command"] as? String == path)
    }

    @Test("Der Befehl für Claude Code gilt für alle Projekte und setzt Pfade mit Leerzeichen in Anführungszeichen")
    func claudeCodeCommand() {
        #expect(MCPSetup.claudeCodeCommand(executablePath: "/Applications/PodcastAI.app/Contents/MacOS/PodcastAI")
                == "claude mcp add --scope user podcastai -- /Applications/PodcastAI.app/Contents/MacOS/PodcastAI --mcp")
        #expect(MCPSetup.claudeCodeCommand(executablePath: "/Users/a/Meine Apps/PodcastAI.app/Contents/MacOS/PodcastAI")
                == "claude mcp add --scope user podcastai -- '/Users/a/Meine Apps/PodcastAI.app/Contents/MacOS/PodcastAI' --mcp")
        #expect(MCPSetup.shellQuoted("/tmp/it's") == #"'/tmp/it'\''s'"#)
        #expect(MCPSetup.isTemporaryLocation("/private/var/folders/x/AppTranslocation/1/d/PodcastAI.app/Contents/MacOS/PodcastAI"))
        #expect(!MCPSetup.isTemporaryLocation("/Applications/PodcastAI.app/Contents/MacOS/PodcastAI"))
    }

    @Test("Obergrenze für limit hält jede Eingabe aus")
    func limitIsClamped() {
        #expect(MCPServer.clampedLimit(nil) == 20)
        #expect(MCPServer.clampedLimit(true) == 20)
        #expect(MCPServer.clampedLimit("abc") == 20)
        #expect(MCPServer.clampedLimit(1e30) == 100)
        #expect(MCPServer.clampedLimit(Double.nan) == 20)
        #expect(MCPServer.clampedLimit(-5) == 1)
        #expect(MCPServer.clampedLimit(7) == 7)
        // So wie die Zahlen wirklich ankommen: aus JSON, als `NSNumber`.
        let decoded = try? JSONSerialization.jsonObject(
            with: Data(#"{"one":1,"zero":0,"yes":true,"half":1.5}"#.utf8)) as? [String: Any]
        #expect(MCPServer.clampedLimit(decoded?["one"]) == 1)
        #expect(MCPServer.clampedLimit(decoded?["zero"]) == 1)
        #expect(MCPServer.clampedLimit(decoded?["yes"]) == 20)
        #expect(MCPServer.clampedLimit(decoded?["half"]) == 1)
    }
}
/// Benutzereinstellungen nur im Arbeitsspeicher. Eine echte Suite legte bei
/// jedem Testlauf eine Datei in ~/Library/Preferences an, die liegen bliebe.
final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { _ = values.removeValue(forKey: defaultName) }
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func bool(forKey defaultName: String) -> Bool {
        (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }
}
#endif
