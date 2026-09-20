"""
Referenzmodell zu PodcastAIMac/MCPServer.swift.

`MCPAccess` war da: Werkzeuge, Freigaben mit Ablauf, Scope, Protokoll. Was
fehlte, war alles dazwischen -- kein JSON-RPC, keine stdio-Schleife, kein
`tools/list`. Eine Werkzeugklasse ohne Server ist kein Zugang.

Ein Zugang fuer fremde Agenten ist eine Angriffsflaeche, und die Regeln
muessen halten, bevor die erste Anfrage kommt. Geprueft wird deshalb
zweierlei:

  * **Das Protokoll.** JSON-RPC 2.0 ist genau genug spezifiziert, um es
    gegen die Spezifikation zu pruefen: Fehlercodes, die Form der `id`,
    und dass eine Benachrichtigung (ohne `id`) *keine* Antwort bekommt.
  * **Die Grenzen.** Kein Werkzeug ohne Freigabe. Keine Obergrenze, die
    der Aufrufer aushebeln kann. Und: eine unbekannte Kennung und eine
    nicht freigegebene sehen von aussen gleich aus -- sonst liesse sich
    ueber die Fehlermeldung herausfinden, welche Kennungen es gibt.

Dazu der Zeilenleser: ein Strom ohne Zeilenende darf den Speicher nicht
fuellen.
"""
import json
import sys

PARSE = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
NOT_AUTHORIZED = -32000

TOOLS = ["listInterests", "searchEvidence", "getEvidence", "listHighlights", "listTrails"]


def clamped_limit(raw, maximum=100):
    """Portierung von MCPServer.clampedLimit."""
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return 20
    if isinstance(raw, float) and (raw != raw or raw in (float("inf"), float("-inf"))):
        return 20
    return min(max(1, int(raw)), maximum)


class Server:
    """Portierung von MCPServer.handle.

    `permits` bildet MCPAccess ab: eingeschaltet, Freigabe vorhanden,
    Werkzeug enthalten, nicht abgelaufen.
    """

    def __init__(self, permitted=frozenset(), known_ids=frozenset()):
        self.permitted = set(permitted)
        self.known_ids = set(known_ids)

    def handle(self, raw):
        try:
            request = json.loads(raw)
        except Exception:
            return self.failure(PARSE, None)
        if not isinstance(request, dict):
            return self.failure(PARSE, None)

        identifier = request.get("id")
        if "method" not in request or not isinstance(request["method"], str):
            return self.failure(INVALID_REQUEST, identifier)

        # Benachrichtigungen bekommen keine Antwort -- auch keine Fehlermeldung.
        if identifier is None:
            return None

        method = request["method"]
        params = request.get("params") or {}

        if method == "initialize":
            return self.result({"protocolVersion": "2025-06-18",
                                "capabilities": {"tools": {"listChanged": False}},
                                "serverInfo": {"name": "podcastai", "version": "1.0.0"}},
                               identifier)
        if method == "ping":
            return self.result({}, identifier)
        if method == "tools/list":
            return self.result({"tools": [{"name": name, "annotations":
                                           {"readOnlyHint": True, "destructiveHint": False}}
                                          for name in TOOLS]}, identifier)
        if method == "tools/call":
            return self.call(params, identifier)
        return self.failure(METHOD_NOT_FOUND, identifier)

    def call(self, params, identifier):
        name = params.get("name")
        if not isinstance(name, str):
            return self.failure(INVALID_PARAMS, identifier)
        if name not in TOOLS:
            return self.failure(METHOD_NOT_FOUND, identifier)
        if name not in self.permitted:
            return self.failure(NOT_AUTHORIZED, identifier)

        arguments = params.get("arguments") or {}

        if name == "searchEvidence":
            query = arguments.get("query")
            if not isinstance(query, str) or not query:
                return self.failure(INVALID_PARAMS, identifier)
            return self.result({"limit": clamped_limit(arguments.get("limit"))}, identifier)

        if name == "getEvidence":
            wanted = arguments.get("id")
            if not isinstance(wanted, str) or not wanted:
                return self.failure(INVALID_PARAMS, identifier)
            if wanted not in self.known_ids:
                # Gleicher Fehler wie "nicht freigegeben".
                return self.failure(NOT_AUTHORIZED, identifier)
            return self.result({"id": wanted}, identifier)

        return self.result({"limit": clamped_limit(arguments.get("limit"))}, identifier)

    @staticmethod
    def result(payload, identifier):
        out = {"jsonrpc": "2.0", "result": payload}
        if identifier is not None:
            out["id"] = identifier
        return out

    @staticmethod
    def failure(code, identifier):
        return {"jsonrpc": "2.0", "error": {"code": code, "message": "…"},
                "id": identifier}


def read_lines(stream, chunk=8, maximum=64):
    """Portierung von LineReader.nextLine."""
    buffer, out, position, finished = b"", [], 0, False
    while True:
        newline = buffer.find(b"\n")
        if newline >= 0:
            out.append(buffer[:newline])
            buffer = buffer[newline + 1:]
            continue
        if finished:
            if buffer:
                out.append(buffer)
            return out
        if len(buffer) > maximum:
            buffer = b""
            out.append(b"")
            continue
        piece = stream[position:position + chunk]
        position += len(piece)
        if not piece:
            finished = True
            continue
        buffer += piece


def main():
    checks = 0
    failures = []

    def expect(condition, note):
        nonlocal checks
        checks += 1
        if not condition:
            failures.append(note)

    full = Server(permitted=set(TOOLS), known_ids={"e1"})
    none = Server()

    # --- Protokoll ---
    expect(full.handle("kein json")["error"]["code"] == PARSE, "kaputtes JSON")
    expect(full.handle("[1,2,3]")["error"]["code"] == PARSE, "JSON, aber kein Objekt")
    expect(full.handle('{"jsonrpc":"2.0","id":1}')["error"]["code"] == INVALID_REQUEST,
           "ohne method")
    expect(full.handle('{"jsonrpc":"2.0","id":1,"method":"gibtsnicht"}')["error"]["code"]
           == METHOD_NOT_FOUND, "unbekannte Methode")

    # Eine Benachrichtigung bekommt keine Antwort. Auch keine Fehlermeldung --
    # das ist der Punkt, an dem eine naive Fassung anfaengt zu plappern.
    for raw in ['{"jsonrpc":"2.0","method":"ping"}',
                '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"gibtsnicht"}}',
                '{"jsonrpc":"2.0","method":"gibtsnicht"}']:
        expect(full.handle(raw) is None, f"Benachrichtigung beantwortet: {raw}")

    # Die `id` kommt in der Form zurueck, in der sie kam: Zahl bleibt Zahl,
    # Zeichenkette bleibt Zeichenkette.
    for identifier in [1, 0, -5, "abc", "0"]:
        response = full.handle(json.dumps(
            {"jsonrpc": "2.0", "id": identifier, "method": "ping"}))
        expect(response["id"] == identifier and type(response["id"]) is type(identifier),
               f"id-Form verloren: {identifier!r}")

    # Ein Fehler ohne brauchbare id antwortet mit null.
    expect(full.handle("kein json")["id"] is None, "Fehler ohne id")

    # tools/list nennt alle Werkzeuge und weist sie als lesend aus.
    listed = full.handle('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')["result"]["tools"]
    expect([t["name"] for t in listed] == TOOLS, "tools/list unvollstaendig")
    expect(all(t["annotations"]["readOnlyHint"] for t in listed), "nicht als lesend markiert")
    expect(not any(t["annotations"]["destructiveHint"] for t in listed), "als veraendernd markiert")

    # --- Grenzen ---
    # Ohne Freigabe geht kein einziges Werkzeug.
    for name in TOOLS:
        response = none.handle(json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": name, "arguments": {"query": "x", "id": "e1"}}}))
        expect(response["error"]["code"] == NOT_AUTHORIZED, f"ohne Freigabe erlaubt: {name}")

    # Ein Tippfehler bleibt ein Tippfehler und wird nicht als fehlende
    # Freigabe getarnt -- sonst sucht man an der falschen Stelle.
    response = full.handle('{"jsonrpc":"2.0","id":1,"method":"tools/call",'
                           '"params":{"name":"listInterest"}}')
    expect(response["error"]["code"] == METHOD_NOT_FOUND, "Tippfehler falsch gemeldet")

    # Unbekannte und nicht freigegebene Kennung sehen gleich aus.
    a = full.handle('{"jsonrpc":"2.0","id":1,"method":"tools/call",'
                    '"params":{"name":"getEvidence","arguments":{"id":"gibtsnicht"}}}')
    b = none.handle('{"jsonrpc":"2.0","id":1,"method":"tools/call",'
                    '"params":{"name":"getEvidence","arguments":{"id":"e1"}}}')
    expect(a["error"]["code"] == b["error"]["code"] == NOT_AUTHORIZED,
           "Kennungen ueber Fehlermeldung unterscheidbar")

    # Fehlende Pflichtangaben.
    for arguments in [{}, {"query": ""}, {"query": 5}]:
        response = full.handle(json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "searchEvidence", "arguments": arguments}}))
        expect(response["error"]["code"] == INVALID_PARAMS, f"query {arguments}")

    # Die Obergrenze laesst sich nicht aushebeln. "Alles" ist kein Scope.
    for raw, expected in [(None, 20), (5, 5), (0, 1), (-1, 1), (100, 100),
                          (1000, 100), (10 ** 9, 100), ("viele", 20),
                          (True, 20), (7.9, 7), (float("inf"), 20),
                          (float("nan"), 20), (1e30, 100), (-1e30, 1),
                          (1.0, 1), (100.5, 100)]:
        expect(clamped_limit(raw) == expected, f"Grenze bei {raw!r}: {clamped_limit(raw)}")

    # --- Zeilenleser ---
    expect(read_lines(b'{"a":1}\n{"b":2}\n') == [b'{"a":1}', b'{"b":2}'], "zwei Zeilen")
    expect(read_lines(b"") == [], "leerer Strom")
    expect(read_lines(b"ohne zeilenende") == [b"ohne zeilenende"], "Rest ohne Zeilenende")
    expect(read_lines(b"\n\n") == [b"", b""], "leere Zeilen")
    expect(read_lines(b"a\nb") == [b"a", b"b"], "letzte Zeile ohne Ende")

    # Eine Zeile ohne Zeilenende darf den Speicher nicht fuellen: sie wird
    # verworfen, der Prozess laeuft weiter.
    overlong = b"x" * 500 + b"\ndanach\n"
    result = read_lines(overlong, maximum=64)
    expect(b"danach" in result, "nach ueberlanger Zeile nicht weitergelesen")
    expect(all(len(line) <= 500 for line in result), "ueberlange Zeile durchgereicht")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"MCP-Server-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"MCP-Server-Referenz: {checks} Pruefungen bestanden "
          f"(JSON-RPC-Fehlercodes, id-Form, Benachrichtigungen ohne Antwort, "
          f"{len(TOOLS)} Werkzeuge ohne Freigabe abgewiesen, Obergrenze, Zeilenleser).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
