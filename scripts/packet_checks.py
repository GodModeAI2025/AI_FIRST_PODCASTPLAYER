"""Executable invariants for SPECIFICATION FIXTURES, not the future Swift app.

Uses only the Python standard library. The schema checker implements precisely the
small schema vocabulary present in this packet, and rejects unsupported keywords.
validate_packet.py additionally runs a full Draft 2020-12 validator when installed.
"""
from __future__ import annotations
import copy
import hashlib
import json
import math
from pathlib import Path
from typing import Any

class PacketError(ValueError):
    """An artifact, fixture or cross-reference violates the packet contract."""

def require(ok: bool, message: str) -> None:
    if not ok:
        raise PacketError(message)

def load(path: Path) -> Any:
    def reject_constant(value: str) -> None:
        raise PacketError(f"Non-finite JSON number: {value}")
    return json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)

def _kind(value: Any, kind: str) -> bool:
    if kind == "null": return value is None
    if kind == "boolean": return type(value) is bool
    if kind == "integer": return type(value) is int
    if kind == "number": return type(value) in (int, float) and math.isfinite(value)
    if kind == "string": return isinstance(value, str)
    if kind == "object": return isinstance(value, dict)
    if kind == "array": return isinstance(value, list)
    raise PacketError(f"Unsupported schema type: {kind}")

def validate_schema(value: Any, schema: dict[str, Any], where: str = "$") -> None:
    supported = {"$schema", "$id", "title", "description", "type", "properties", "required",
                 "additionalProperties", "items", "minItems", "maxItems", "uniqueItems",
                 "minLength", "maxLength", "enum", "const", "minimum", "maximum",
                 "exclusiveMinimum", "exclusiveMaximum"}
    require(set(schema) <= supported, f"{where}: unsupported schema keywords {set(schema)-supported}")
    if "type" in schema:
        kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        require(any(_kind(value, k) for k in kinds), f"{where}: expected {kinds}")
    if "const" in schema:
        expected = schema["const"]
        require(value == expected and not (isinstance(value, bool) ^ isinstance(expected, bool)), f"{where}: const")
    if "enum" in schema:
        require(any(value == x and not (isinstance(value, bool) ^ isinstance(x, bool)) for x in schema["enum"]), f"{where}: enum")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        require(set(schema.get("required", [])) <= set(value), f"{where}: missing required properties")
        if schema.get("additionalProperties") is False:
            require(set(value) <= set(props), f"{where}: unexpected properties {set(value)-set(props)}")
        for k, v in value.items():
            if k in props: validate_schema(v, props[k], f"{where}.{k}")
    if isinstance(value, list):
        require(len(value) >= schema.get("minItems", 0), f"{where}: too few items")
        require(len(value) <= schema.get("maxItems", math.inf), f"{where}: too many items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(v, sort_keys=True, ensure_ascii=False) for v in value]
            require(len(encoded) == len(set(encoded)), f"{where}: duplicate items")
        for n, v in enumerate(value):
            if "items" in schema: validate_schema(v, schema["items"], f"{where}[{n}]")
    if isinstance(value, str):
        require(len(value) >= schema.get("minLength", 0), f"{where}: string too short")
        require(len(value) <= schema.get("maxLength", math.inf), f"{where}: string too long")
    if type(value) in (int, float):
        require(math.isfinite(value), f"{where}: not finite")
        if "minimum" in schema: require(value >= schema["minimum"], f"{where}: minimum")
        if "maximum" in schema: require(value <= schema["maximum"], f"{where}: maximum")
        if "exclusiveMinimum" in schema: require(value > schema["exclusiveMinimum"], f"{where}: exclusiveMinimum")
        if "exclusiveMaximum" in schema: require(value < schema["exclusiveMaximum"], f"{where}: exclusiveMaximum")

def by_id(values: list[dict[str, Any]], label: str) -> dict[str, dict[str, Any]]:
    result = {v["id"]: v for v in values}
    require(len(result) == len(values), f"{label}: duplicate id")
    return result

def check_range(r: dict[str, int], duration: int | None = None) -> None:
    require(type(r.get("startMs")) is int and type(r.get("endMs")) is int, "range: integer times required")
    require(0 <= r["startMs"] < r["endMs"] <= 9_007_199_254_740_991, "range: invalid order or bounds")
    if duration is not None: require(r["endMs"] <= duration, "range: exceeds media duration")

def includes(outer: dict[str, int], inner: dict[str, int]) -> bool:
    return outer["startMs"] <= inner["startMs"] < inner["endMs"] <= outer["endMs"]

def validate_corpus(corpus: dict[str, Any]) -> None:
    require(corpus.get("synthetic") is True, "corpus: must be explicitly synthetic")
    media = by_id(corpus["media"], "media")
    transcripts = by_id(corpus["transcripts"], "transcripts")
    evidence = by_id(corpus["evidence"], "evidence")
    for t in transcripts.values():
        m = media.get(t.get("mediaVersionID"))
        if t["timingStatus"] == "verified": require(m is not None, "transcript: verified timing without media")
        by_id(t["segments"], "segments")
        for s in t["segments"]:
            if "range" in s: check_range(s["range"], m["durationMs"] if m else None)
            if t["timingStatus"] == "verified": require("range" in s and s["final"], "verified transcript contains untimed/provisional segment")
            for word in s.get("words", []):
                check_range(word["range"])
                require("range" in s and includes(s["range"], word["range"]), "word: outside segment")
    for e in evidence.values():
        require(e["transcriptRevisionID"] in transcripts, "evidence: missing transcript")
        t = transcripts[e["transcriptRevisionID"]]
        segments = by_id(t["segments"], "segments")
        require(set(e["segmentIDs"]) <= set(segments), "evidence: invented segment id")
        require(len(e["segmentIDs"]) == len(set(e["segmentIDs"])), "evidence: repeated segment id")
        original = " ".join(segments[i]["text"] for i in e["segmentIDs"])
        require(e["excerpt"] in original, "evidence: excerpt not present in source segments")
        if e["timingStatus"] == "verified":
            require(e.get("mediaVersionID") == t.get("mediaVersionID") and e.get("mediaVersionID") in media, "evidence: wrong media revision")
            require(t["timingStatus"] == "verified" and "range" in e, "evidence: unverified timing")
            m = media[e["mediaVersionID"]]
            require(e["episodeID"] == m["episodeID"], "evidence: wrong episode")
            check_range(e["range"], m["durationMs"])
            lo = min(segments[i]["range"]["startMs"] for i in e["segmentIDs"])
            hi = max(segments[i]["range"]["endMs"] for i in e["segmentIDs"])
            require(includes({"startMs": lo, "endMs": hi}, e["range"]), "evidence: time outside cited segments")
    eps = {m["episodeID"] for m in media.values()}
    require(set(corpus["analyzedEpisodeIDs"]) <= eps, "unknown analyzed episode")
    require(set(corpus["playedEpisodeIDs"]) <= eps, "unknown played episode")

def plan_hash(plan: dict[str, Any]) -> str:
    """Fixture canonicalization; shipping Swift must match a documented wire format."""
    value = {k: v for k, v in plan.items() if k != "planHash"}
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()

def validate_plan(plan: dict[str, Any], corpus: dict[str, Any]) -> None:
    require(plan["planHash"] == plan_hash(plan), "plan: digest mismatch")
    media, evidence = by_id(corpus["media"], "media"), by_id(corpus["evidence"], "evidence")
    require(bool(plan["segments"]), "plan: empty")
    by_id(plan["segments"], "plan segments")
    rate = plan["playbackRate"]
    require(type(rate) in (int, float) and math.isfinite(rate) and 0 < rate <= 4, "plan: invalid rate")
    total = 0
    for s in plan["segments"]:
        require(s["mediaVersionID"] in media, "plan: missing media")
        m = media[s["mediaVersionID"]]
        require(m["identityStatus"] == "verified" and m["capabilities"]["timedPlayback"], "plan: media identity or capability")
        require(m["capabilities"]["nativeAudio"], "fixture plan requires authorized native audio")
        require(m["episodeID"] == s["episodeID"], "plan: wrong episode")
        check_range(s["playbackRange"], m["durationMs"]); check_range(s["coreRange"], m["durationMs"])
        require(includes(s["playbackRange"], s["coreRange"]), "plan: playback excludes core")
        require(bool(s["evidenceIDs"]), "plan: no evidence")
        core_covered = False
        for eid in s["evidenceIDs"]:
            require(eid in evidence, "plan: invented evidence")
            e = evidence[eid]
            require(e["mediaVersionID"] == s["mediaVersionID"] and e["transcriptRevisionID"] == s["transcriptRevisionID"], "plan: evidence revision mismatch")
            require(e["timingStatus"] == "verified", "plan: unverified evidence time")
            require(includes(s["playbackRange"], e["range"]), "plan: evidence excluded from playback")
            core_covered |= includes(e["range"], s["coreRange"])
        require(core_covered, "plan: core not grounded in evidence")
        total += s["playbackRange"]["endMs"] - s["playbackRange"]["startMs"]
    require(type(plan["transitionMs"]) is int and plan["transitionMs"] >= 0, "plan: transition")
    duration = math.ceil(total / rate) + (len(plan["segments"]) - 1) * plan["transitionMs"]
    require(plan["estimatedListeningMs"] == duration, "plan: listening estimate mismatch")
    require(duration <= plan["activeListeningBudgetMs"], "plan: exceeds approved listening budget")

def validate_grant(grant: dict[str, Any], plan: dict[str, Any], *, device: str,
                   session: str, now: int, consent_revision: int) -> None:
    require(not grant["consumed"], "grant: already consumed")
    require(grant["deviceID"] == device and grant["sessionID"] == session, "grant: wrong execution context")
    require(grant["planHash"] == plan["planHash"], "grant: wrong plan")
    require(grant["consentRevision"] == consent_revision, "grant: stale consent")
    require(grant["issuedAtEpochMs"] <= now < grant["expiresAtEpochMs"], "grant: expired or not yet valid")
    require(grant["kind"] in {"explicitUI", "explicitChat", "explicitIntent"}, "grant: not explicit")

def validate_answer(answer: dict[str, Any], corpus: dict[str, Any]) -> None:
    selected, analyzed, used = map(set, [answer["selectedEpisodeIDs"], answer["analyzedEpisodeIDs"], answer["usedEpisodeIDs"]])
    require(used <= analyzed <= selected, "answer: invalid coverage or scope")
    ev = by_id(corpus["evidence"], "evidence")
    cited = set()
    for claim in answer["claims"]:
        require(bool(claim["evidenceIDs"]), "answer: ungrounded claim")
        for eid in claim["evidenceIDs"]:
            require(eid in ev and ev[eid]["episodeID"] in used, "answer: out-of-scope evidence")
            cited.add(ev[eid]["episodeID"])
    require(cited == used, "answer: used episode count not backed by citations")
    if answer["status"] == "noEvidence": require(not answer["claims"], "answer: noEvidence still contains claims")

def validate_archive(a: dict[str, Any]) -> None:
    require(len(a["selectedEpisodeIDs"]) == len(set(a["selectedEpisodeIDs"])), "archive: duplicate selection")
    require(a["analyzedCount"] <= a["analyzableCount"] <= a["discoveredCount"], "archive: impossible counts")
    require(a["analyzableCount"] + a["unavailableCount"] <= a["discoveredCount"], "archive: overlapping access counts")
    if a["catalogState"] == "complete": require(a["nextCursor"] is None, "archive: complete with more pages")
    if a["analysisState"] == "complete": require(a["analyzedCount"] == a["analyzableCount"], "archive: false analysis completion")

def validate_stance(s: dict[str, Any]) -> None:
    if s["status"] == "confirmed": require(s["origin"] == "explicitUser", "stance: implicit belief attribution")
    require(not (s["sensitivity"] in {"political", "sensitive"} and s["origin"] == "modelSuggestion"), "stance: inferred sensitive belief")

def validate_counterpoint(c: dict[str, Any], stance: dict[str, Any], corpus: dict[str, Any]) -> None:
    validate_stance(stance)
    require(c["targetStanceID"] == stance["id"], "counterpoint: unknown target")
    require(c["targetStanceRevision"] == stance["revision"] or c["state"] == "stale", "counterpoint: old stance")
    require(stance["status"] not in {"withdrawn", "rejected"} or c["state"] == "stale", "counterpoint: withdrawn target")
    if stance["sensitivity"] == "political": require(c["mode"] == "neutralComparison", "counterpoint: political personalization")
    if c["state"] == "noEvidence": require(not c["relations"] and "planID" not in c, "counterpoint: invented noEvidence plan")
    ev = by_id(corpus["evidence"], "evidence")
    for relation in c["relations"]:
        require(bool(relation["evidenceIDs"]), "counterpoint: no citations")
        require(set(relation["evidenceIDs"]) <= set(ev), "counterpoint: missing evidence")

def validate_graph(graph: dict[str, Any], corpus: dict[str, Any]) -> None:
    nodes, edges, ev = by_id(graph["nodes"], "graph nodes"), by_id(graph["edges"], "graph edges"), by_id(corpus["evidence"], "evidence")
    scope = set(graph["scopeEpisodeIDs"])
    for node in nodes.values():
        for eid in node["evidenceIDs"]:
            require(eid in ev and ev[eid]["episodeID"] in scope, "graph: invalid/out-of-scope node evidence")
        if node["kind"] in {"claim", "evidence"} and node["origin"] == "source" and node["sourceStatus"] == "available":
            require(bool(node["evidenceIDs"]), "graph: available source assertion lacks evidence")
    for edge in edges.values():
        require(edge["fromID"] in nodes and edge["toID"] in nodes, "graph: dangling edge")
        require(edge["fromID"] != edge["toID"], "graph: self-edge")
        for eid in edge["evidenceIDs"]:
            require(eid in ev and ev[eid]["episodeID"] in scope, "graph: invalid edge evidence")
        if edge["relation"] in {"contradicts", "qualifies", "differentAssumptions"}:
            require(bool(edge["evidenceIDs"]), "graph: ungrounded argument relation")
            require(edge["reviewStatus"] != "systemVerified", "graph: interpretive relation is not machine-proven truth")
        if edge["relation"] == "supportedBy": require(nodes[edge["toID"]]["kind"] == "evidence", "graph: supportedBy must point to evidence")

def validate_closure(c: dict[str, Any], corpus: dict[str, Any], catalog: dict[str, Any], graph: dict[str, Any]) -> None:
    ev = by_id(corpus["evidence"], "evidence")
    episodes = {x["episodeID"]: x for x in catalog["entries"]}
    sources = set()
    for eid in c["sourceEvidenceIDs"]:
        require(eid in ev and ev[eid]["episodeID"] in episodes, "closure: missing source evidence")
        item = episodes[ev[eid]["episodeID"]]
        require(item["available"], "closure: inaccessible offered source")
        sources.add(item["originalRecordingID"])
    require(c["uniqueSourceCount"] == len(sources), "closure: fabricated source count")
    require(c["graphID"] == graph["id"] and c["sessionID"] == graph["sessionID"], "closure: wrong graph/session")
    require(c["startNextAutomatically"] is False, "closure: automatic endless playback")
    if c["reason"] in {"interrupted", "sleepTimer"}:
        require(c["state"] in {"running", "paused"} and c["choice"] == "unanswered", "closure: interruption wrongly finalized")
    if c["choice"] != "park": require(c["exportState"] == "notRequested", "closure: export without park request")
    require(c["parentSessionID"] != c["sessionID"], "closure: self parent")

def session_transition(state: str, event: str) -> str:
    """Reference contract model, not a production playback state machine."""
    require(state in {"running", "paused", "closing", "closed"}, "unknown state")
    if event in {"pause", "headphonesDisconnected", "interrupted", "sleepTimer"} and state in {"running", "paused"}: return "paused"
    if event == "resume" and state == "paused": return "running"
    if event in {"budgetEnd", "naturalEnd", "explicitEnd"} and state in {"running", "paused"}: return "closing"
    if event in {"park", "discard", "dismiss"} and state == "closing": return "closed"
    return state

def task_order(tasks: list[dict[str, Any]]) -> list[str]:
    mapping = by_id(tasks, "tasks")
    temporary, done, order = set(), set(), []
    def visit(tid: str) -> None:
        require(tid in mapping, "task: missing dependency")
        require(tid not in temporary, "task: cyclic dependency")
        if tid in done: return
        temporary.add(tid)
        for dep in mapping[tid]["dependsOn"]: visit(dep)
        temporary.remove(tid); done.add(tid); order.append(tid)
    for tid in mapping: visit(tid)
    return order

def safe_relative(root: Path, rel: str) -> Path:
    p = (root / rel).resolve()
    require(p.is_relative_to(root.resolve()), f"Path escapes packet: {rel}")
    return p

def validate_traceability(root: Path) -> dict[str, int]:
    p = root / "specs/001-ai-podcast-player"
    r = by_id(load(p/"requirements.json")["requirements"], "requirements")
    s = by_id(load(p/"stories.json")["stories"], "stories")
    tlist = load(p/"tasks.json")["tasks"]
    t = by_id(tlist, "tasks"); task_order(tlist)
    a = by_id(load(p/"acceptance-cases.json")["cases"], "acceptance")
    links = load(p/"traceability.json")["links"]
    require(len(links) == len(r) and {x["requirement"] for x in links} == set(r), "trace: requirement coverage")
    for x in links:
        rid = x["requirement"]
        require(x["story"] == r[rid]["story"] and x["story"] in s, "trace: story mismatch")
        require(x["implementationTask"] in t and x["testTask"] in t, "trace: missing task")
        require(x["acceptanceCase"] in a and a[x["acceptanceCase"]]["requirement"] == rid, "trace: wrong acceptance")
        require(t[x["implementationTask"]]["path"] == x["targetPath"], "trace: path mismatch")
        require(t[x["testTask"]]["path"] == a[x["acceptanceCase"]]["testTarget"], "trace: test path mismatch")
    require({x["story"] for x in r.values()} == set(s), "trace: orphan story")
    require(all(x["status"] == "not_started" for x in t.values()), "tasks misrepresented as implemented")
    require(all(x["status"] == "planned_not_executed" for x in a.values()), "acceptance misrepresented as executed")
    # Every implementation must precede the final device builds, including appended features.
    seen = set()
    def ancestors(tid: str) -> None:
        for dep in t[tid]["dependsOn"]:
            if dep not in seen: seen.add(dep); ancestors(dep)
    ancestors("T099")
    require({x["implementationTask"] for x in links} <= seen, "release builds precede implementation")
    require({f"T{i:03d}" for i in range(100,109)} <= set(t["T109"]["dependsOn"]), "convergence omits verification gates")
    spec, tasks_text = (p/"spec.md").read_text(), (p/"tasks.md").read_text()
    for rid in r: require(rid in spec, f"spec missing {rid}")
    for tid in t: require(tid in tasks_text, f"tasks.md missing {tid}")
    return {"requirements":len(r), "stories":len(s), "tasks":len(t), "acceptanceCases":len(a)}

def validate_packet(root: Path, *, verify_manifest: bool = True) -> dict[str, Any]:
    stats = validate_traceability(root)
    for p in root.rglob("*.json"):
        if "__pycache__" not in p.parts: load(p)
    manifest = load(root/"fixtures/manifest.json")
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        Draft202012Validator = None
    for item in manifest["fixtures"]:
        data = load(safe_relative(root, item["path"])); schema = load(safe_relative(root, item["schema"]))
        require(item["synthetic"], "fixture missing synthetic status")
        validate_schema(data, schema, item["path"])
        if Draft202012Validator:
            Draft202012Validator.check_schema(schema)
            Draft202012Validator(schema).validate(data)
    corpus = load(root/"fixtures/corpus.json"); validate_corpus(corpus)
    for section in ["media", "transcripts", "evidence"]:
        for obj in corpus[section]: require(load(root/f"fixtures/valid/{obj['id']}.json") == obj, "standalone/corpus fixture divergence")
    plan = load(root/"fixtures/valid/plan.json"); validate_plan(plan, corpus)
    grant = load(root/"fixtures/valid/grant.json")
    validate_grant(grant, plan, device="device-demo", session="session-demo", now=2000, consent_revision=1)
    validate_answer(load(root/"fixtures/valid/answer.json"), corpus)
    validate_archive(load(root/"fixtures/valid/archive.json"))
    stance = load(root/"fixtures/valid/stance.json")
    validate_counterpoint(load(root/"fixtures/valid/counterpoint.json"), stance, corpus)
    graph = load(root/"fixtures/valid/graph.json"); validate_graph(graph, corpus)
    require(load(root/"fixtures/export/trail/graph.json") == graph, "graph export differs from source snapshot")
    validate_closure(load(root/"fixtures/valid/session-closure.json"), corpus, load(root/"fixtures/source-catalog.json"), graph)
    from smart_feed_checks import validate_smart_feed_fixtures
    validate_smart_feed_fixtures(root, corpus)
    from xml.etree import ElementTree
    for p in list((root/"fixtures").rglob("*.xml"))+list((root/"fixtures").rglob("*.atom")): ElementTree.parse(p)
    images = load(root/"design/image-manifest.json")
    for image in images["images"]:
        p = safe_relative(root, image["path"])
        require(p.is_file() and p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n", "image missing or not PNG")
    require((root/"design/images/brainspeak-original-10-screens.png").is_file(), "original design image missing")
    counts = {"schemaFixtures":len(manifest["fixtures"]), "images":len(images["images"])+1, "syntheticSources":len(corpus["media"])}
    integrity = "not_requested_or_not_yet_created"
    inventory = root/"PACKAGE_MANIFEST.json"
    if verify_manifest and inventory.exists():
        pack = load(inventory)
        for item in pack["files"]:
            p = safe_relative(root, item["path"])
            require(p.is_file(), f"inventory missing {item['path']}")
            require(hashlib.sha256(p.read_bytes()).hexdigest() == item["sha256"], f"inventory hash mismatch {item['path']}")
        integrity = "passed"
    return {"status":"passed", "scope":"specification_packet_only", **stats, **counts,
            "schemaEngine":"stdlib_supported_vocabulary_plus_jsonschema_Draft202012Validator" if Draft202012Validator else "stdlib_supported_vocabulary_only",
            "inventory":integrity,
            "note":"Prueft nur Spezifikation und Beispieldaten. Die App selbst wird mit Xcode gebaut und getestet, siehe app/README.md."}
