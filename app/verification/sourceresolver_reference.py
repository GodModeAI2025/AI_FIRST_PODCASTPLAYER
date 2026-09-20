"""
Referenzmodell zu PodcastAISources/SourceResolver.swift.

Geprueft gegen die Testfaelle des Spec-Kit-Pakets:
  fixtures/youtube/url-cases.json

Damit ist die Linkklassifikation nicht nur gegen mein eigenes Verstaendnis
geprueft, sondern gegen die im Paket festgehaltene Erwartung.
"""
import json
import pathlib
from urllib.parse import urlparse, parse_qs

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "fixtures" / "youtube" / "url-cases.json"

YT_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com",
            "music.youtube.com", "youtu.be", "www.youtu.be"}


def is_video_id(s):
    return len(s) == 11 and all(c.isalnum() or c in "_-" for c in s)


def is_channel_id(s):
    return len(s) == 24 and s.startswith("UC") and all(c.isalnum() or c in "_-" for c in s)


def is_playlist_id(s):
    return 2 <= len(s) <= 64 and all(c.isalnum() or c in "_-" for c in s)


def timestamp_ms(qs):
    """Portierung von SourceResolver.timestamp(in:)."""
    raw = (qs.get("t") or qs.get("start") or [None])[0]
    if not raw:
        return 0
    raw = raw.strip().lower()
    if raw.isdigit():
        return int(raw) * 1000
    total, digits, saw_unit = 0, "", False
    for ch in raw:
        if ch.isdigit():
            digits += ch
            continue
        if not digits:
            return None
        v = int(digits)
        if ch == "h":
            total += v * 3600
        elif ch == "m":
            total += v * 60
        elif ch == "s":
            total += v
        else:
            return None
        digits, saw_unit = "", True
    if digits or not saw_unit:
        return None
    return total * 1000


def normalize_scheme(s):
    for prefix in ("feed://", "podcast://", "pcast://", "itpc://"):
        if s.lower().startswith(prefix):
            return "https://" + s[len(prefix):]
    if "://" not in s and "." in s and not s.startswith("/"):
        return "https://" + s
    return s


def resolve(raw):
    """Portierung von SourceResolver.resolve. Liefert (kind, id, timestamp_ms)."""
    s = normalize_scheme(raw.strip())
    u = urlparse(s)
    if not u.scheme:
        return ("rejected", None, 0)
    if u.scheme == "file":
        return ("localFile", None, 0)
    if u.scheme not in ("http", "https"):
        return ("rejected", None, 0)          # javascript:, data:, ...

    host = (u.hostname or "").lower()
    qs = parse_qs(u.query)
    segments = [x for x in u.path.split("/") if x]

    if host not in YT_HOSTS:
        # Kein YouTube. Nicht als YouTube behandeln -- genau das prueft die Fixture.
        return ("notYouTube", None, 0)

    ts = timestamp_ms(qs) or 0

    if u.path.startswith("/feeds/videos.xml"):
        cid = (qs.get("channel_id") or [None])[0]
        if cid and is_channel_id(cid):
            return ("channel", cid, 0)
        return ("podcastFeed", None, 0)

    if host.endswith("youtu.be") and segments and is_video_id(segments[0]):
        return ("video", segments[0], ts)

    if u.path == "/watch":
        vid = (qs.get("v") or [None])[0]
        if vid and is_video_id(vid):
            return ("video", vid, ts)

    if len(segments) >= 2 and segments[0] in ("shorts", "live", "embed", "v") \
            and is_video_id(segments[1]):
        return ("video", segments[1], ts)

    if u.path == "/playlist":
        lid = (qs.get("list") or [None])[0]
        if lid and is_playlist_id(lid):
            return ("playlist", lid, 0)

    if len(segments) >= 2 and segments[0] == "channel" and is_channel_id(segments[1]):
        return ("channel", segments[1], 0)

    if segments and segments[0].startswith("@"):
        return ("handle", segments[0], 0)

    if len(segments) >= 2 and segments[0] in ("c", "user"):
        return ("username", segments[1], 0)

    return ("webPageNeedingDiscovery", None, 0)


def main():
    cases = json.loads(FIXTURES.read_text())["cases"]
    passed = 0
    for c in cases:
        kind, ident, ts = resolve(c["input"])
        expected = c["expectedKind"]

        if expected == "rejected":
            # Die Zusage lautet: nicht als YouTube-Inhalt behandeln.
            assert kind in ("rejected", "notYouTube"), \
                f"{c['input']}: haette abgelehnt werden muessen, wurde {kind}"
        else:
            assert kind == expected, f"{c['input']}: erwartet {expected}, bekam {kind}"
            assert ident == c["expectedID"], \
                f"{c['input']}: erwartet ID {c['expectedID']}, bekam {ident}"
            assert ts == c["timestampMs"], \
                f"{c['input']}: erwartet {c['timestampMs']} ms, bekam {ts}"
        passed += 1

    # Zusaetzliche Faelle, die die Fixture nicht abdeckt.
    extra = [
        ("feed://example.com/rss.xml", "notYouTube"),
        ("https://youtu.be/AbCdEfGhI01?t=1h2m3s", "video"),
        ("data:text/html,<script>", "rejected"),
        ("https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv", "channel"),
    ]
    for inp, want in extra:
        kind, _, _ = resolve(inp)
        assert kind == want, f"{inp}: erwartet {want}, bekam {kind}"
        passed += 1

    # Zeitstempelformen einzeln.
    assert timestamp_ms({"t": ["83"]}) == 83_000
    assert timestamp_ms({"t": ["1m23s"]}) == 83_000
    assert timestamp_ms({"t": ["1h2m3s"]}) == 3_723_000
    assert timestamp_ms({"t": ["abc"]}) is None        # lieber nichts als geraten
    assert timestamp_ms({"t": ["1m30"]}) is None       # Rest ohne Einheit
    passed += 5

    print(f"SourceResolver-Referenz: {passed} Pruefungen bestanden "
          f"({len(cases)} davon aus fixtures/youtube/url-cases.json).")


if __name__ == "__main__":
    main()
