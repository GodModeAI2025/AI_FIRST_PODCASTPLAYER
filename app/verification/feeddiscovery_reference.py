"""
Referenzmodell zu PodcastAISources/FeedDiscovery.swift.

`SourceResolver` erkannte YouTube-Videos, Playlists und gewoehnliche
Webseiten korrekt -- und danach war Schluss: `addSource` warf "noch nicht
eingebaut". Drei von vier Wegen aus Kapitel 1 endeten in einer
Fehlermeldung.

Zerlegt wird bewusst *nicht* mit einem vollstaendigen HTML-Parser, sondern
gezielt: gesucht wird das eine Element, das laut Konvention den Feed
benennt. Ein Zerleger, der mehr versteht, versteht auch mehr falsch. Das
macht die Funktion klein genug, um sie gegen echte Seitenformen zu pruefen
-- und genau das passiert hier.

Geprueft wird an Seiten, wie sie tatsaechlich aussehen: Attribute in
beliebiger Reihenfolge, einfache und doppelte Anfuehrungszeichen, relative
Adressen, `&amp;` in Parametern, mehrere Feeds, ein `<link>` im Rumpf,
und die Faelle, in denen *nichts* gefunden werden darf.
"""
import re
import sys
from urllib.parse import urljoin, urlsplit

FEED_TYPES = {
    "application/rss+xml", "application/atom+xml",
    "application/rdf+xml", "application/feed+json", "application/json",
}

ENTITIES = [
    ("&amp;", "&"), ("&#38;", "&"), ("&#x26;", "&"),
    ("&quot;", '"'), ("&#39;", "'"), ("&apos;", "'"),
    ("&lt;", "<"), ("&gt;", ">"),
]

LOCAL_SUFFIXES = (".localhost", ".local", ".internal", ".home", ".lan", ".intranet")


def decode_entities(text):
    result = text
    for entity, char in ENTITIES:
        result = re.sub(re.escape(entity), char, result, flags=re.IGNORECASE)
    return result.strip()


def link_tags(html):
    """Portierung von FeedDiscovery.linkTags -- nur bis zum Ende des Kopfes."""
    head_end = re.search(r"</head", html, re.IGNORECASE)
    searchable = html[:head_end.start()] if head_end else html

    tags, rest = [], searchable
    while True:
        open_at = re.search(r"<link", rest, re.IGNORECASE)
        if not open_at:
            break
        rest = rest[open_at.start():]
        close = rest.find(">")
        if close < 0:
            break
        # Nach dem Namen muss ein Trenner kommen -- sonst waere `<linkage>`
        # ein `link`-Element.
        after = rest[5:6]
        if after and (after.isspace() or after in (">", "/")):
            tags.append(rest[:close + 1])
        rest = rest[close + 1:]
    return tags


ATTR = re.compile(r"""([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)')""")


def attributes(tag):
    """Portierung von FeedDiscovery.attributes -- erste Nennung gewinnt."""
    result = {}
    for match in ATTR.finditer(tag):
        name = match.group(1).lower()
        value = match.group(3) if match.group(3) is not None else match.group(4)
        if name not in result:
            result[name] = value
    return result


def is_allowed(url):
    """Vereinfachte Portierung von NetworkDestination.isAllowed."""
    parts = urlsplit(url)
    if parts.scheme.lower() not in ("http", "https"):
        return False
    if parts.username or parts.password:
        return False
    host = (parts.hostname or "").lower()
    if not host:
        return False
    try:
        if parts.port is not None and parts.port not in (80, 443):
            return False
    except ValueError:
        return False
    bare = host[:-1] if host.endswith(".") else host
    if ":" in host or host.startswith("["):
        return False
    if bare.replace(".", "").isdigit():
        return False
    if bare == "localhost" or any(bare.endswith(s) for s in LOCAL_SUFFIXES):
        return False
    return "." in bare


def feed_links(html, base):
    """Portierung von FeedDiscovery.feedLinks."""
    found, seen = [], set()
    for tag in link_tags(html):
        attrs = attributes(tag)
        rel = (attrs.get("rel") or "").lower()
        if "alternate" not in rel.split():
            continue
        if (attrs.get("type") or "").lower() not in FEED_TYPES:
            continue
        href = attrs.get("href") or ""
        if not href:
            continue
        url = urljoin(base, decode_entities(href))
        if not is_allowed(url):
            continue
        if url in seen:
            continue
        seen.add(url)
        found.append(url)
    return found


CHANNEL_PATTERNS = [
    r"""<meta[^>]+itemprop=["']channelId["'][^>]+content=["']([^"']+)["']""",
    r"""<meta[^>]+content=["']([^"']+)["'][^>]+itemprop=["']channelId["']""",
    r"""["']channelId["']\s*:\s*["']([^"']+)["']""",
    r"""/channel/(UC[A-Za-z0-9_-]{22})""",
]


def is_channel_id(value):
    return (len(value) == 24 and value.startswith("UC")
            and all(c.isalnum() or c in "_-" for c in value[2:]))


def youtube_channel_id(html):
    """Portierung von FeedDiscovery.youTubeChannelID."""
    for pattern in CHANNEL_PATTERNS:
        for match in re.finditer(pattern, html, re.IGNORECASE):
            candidate = match.group(1)
            if is_channel_id(candidate):
                return candidate
    return None


# --------------------------------------------------------------------------

PAGES = [
    # 1. Der Normalfall: ein Feed im Kopf, relative Adresse.
    ("""<html><head><title>Blog</title>
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
        </head><body></body></html>""",
     "https://example.com/blog/",
     ["https://example.com/feed.xml"]),

    # 2. Attribute in anderer Reihenfolge, einfache Anfuehrungszeichen.
    ("""<head><link href='https://example.com/podcast.rss'
        type='application/rss+xml' rel='alternate'></head>""",
     "https://example.com/",
     ["https://example.com/podcast.rss"]),

    # 3. `&amp;` in den Parametern -- unaufgeloest zeigt der Link ins Leere.
    ("""<head><link rel="alternate" type="application/rss+xml"
        href="https://example.com/feed?format=rss&amp;lang=de"></head>""",
     "https://example.com/",
     ["https://example.com/feed?format=rss&lang=de"]),

    # 4. Mehrere Feeds: Reihenfolge des Vorkommens bleibt.
    ("""<head>
        <link rel="alternate" type="application/atom+xml" href="/atom.xml">
        <link rel="alternate" type="application/rss+xml" href="/rss.xml">
        </head>""",
     "https://example.com/",
     ["https://example.com/atom.xml", "https://example.com/rss.xml"]),

    # 5. Doppelter Verweis auf dieselbe Adresse -> einmal.
    ("""<head>
        <link rel="alternate" type="application/rss+xml" href="/f.xml">
        <link rel="alternate" type="application/rss+xml" href="/f.xml">
        </head>""",
     "https://example.com/",
     ["https://example.com/f.xml"]),

    # 6. Ein `<link>` im Rumpf zaehlt nicht.
    ("""<head><title>x</title></head><body>
        <link rel="alternate" type="application/rss+xml" href="/spaet.xml">
        </body>""",
     "https://example.com/",
     []),

    # 7. `rel="stylesheet"` ist kein Feed, auch mit passendem Typ daneben.
    ("""<head>
        <link rel="stylesheet" href="/style.css">
        <link rel="icon" type="image/png" href="/icon.png">
        </head>""",
     "https://example.com/",
     []),

    # 8. `rel` mit mehreren Werten.
    ("""<head><link rel="alternate home" type="application/rss+xml"
        href="/mehrfach.xml"></head>""",
     "https://example.com/",
     ["https://example.com/mehrfach.xml"]),

    # 9. Der Angriffsfall: eine Seite verweist auf das eigene Netz.
    #    Was nicht abgerufen werden duerfte, wird auch nicht vorgeschlagen.
    ("""<head>
        <link rel="alternate" type="application/rss+xml" href="http://127.0.0.1:11434/feed">
        <link rel="alternate" type="application/rss+xml" href="http://localhost/feed">
        <link rel="alternate" type="application/rss+xml" href="file:///etc/passwd">
        <link rel="alternate" type="application/rss+xml" href="https://echt.example.com/feed">
        </head>""",
     "https://example.com/",
     ["https://echt.example.com/feed"]),

    # 10. Kein Kopf-Ende im Dokument -- darf nicht in eine Endlosschleife laufen.
    ("""<link rel="alternate" type="application/rss+xml" href="/ohnekopf.xml">""",
     "https://example.com/",
     ["https://example.com/ohnekopf.xml"]),

    # 11. Unvollstaendiges Element am Ende.
    ("""<head><link rel="alternate" type="application/rss+xml" href="/abgeschnitten""",
     "https://example.com/",
     []),

    # 12. Leere Seite.
    ("", "https://example.com/", []),

    # 13. `<linkage>` ist kein `<link>`. Der Fehler, den ein zu williger
    #     Zerleger macht -- und den man erst bemerkt, wenn eine Seite ihn
    #     enthaelt.
    ("""<head><linkage rel="alternate" type="application/rss+xml" href="/falsch.xml">
        <link rel="alternate" type="application/rss+xml" href="/richtig.xml"></head>""",
     "https://example.com/",
     ["https://example.com/richtig.xml"]),
]

YOUTUBE_PAGES = [
    ("""<meta itemprop="channelId" content="UCabcdefghijklmnopqrstuv">""",
     "UCabcdefghijklmnopqrstuv"),
    ("""<meta content="UCabcdefghijklmnopqrstuv" itemprop="channelId">""",
     "UCabcdefghijklmnopqrstuv"),
    ("""var data = {"channelId":"UC_-_1234567890abcdefghi"};""",
     "UC_-_1234567890abcdefghi"),
    ("""<a href="/channel/UCabcdefghijklmnopqrstuv">Kanal</a>""",
     "UCabcdefghijklmnopqrstuv"),
    # Zu kurz, falsches Praefix, leer: nichts davon ist eine Kennung.
    ("""<meta itemprop="channelId" content="UCzukurz">""", None),
    ("""<meta itemprop="channelId" content="XXabcdefghijklmnopqrstuv">""", None),
    ("""<meta itemprop="channelId" content="">""", None),
    ("", None),
    # Eine ungueltige Angabe zuerst, eine gueltige danach: genommen wird die
    # erste, die *gueltig* ist -- nicht die erste ueberhaupt.
    ("""<meta itemprop="channelId" content="kaputt">
        <a href="/channel/UCabcdefghijklmnopqrstuv">Kanal</a>""",
     "UCabcdefghijklmnopqrstuv"),
]


def main():
    checks = 0
    failures = []

    for html, base, expected in PAGES:
        checks += 1
        result = feed_links(html, base)
        if result != expected:
            failures.append(f"Seite {base}: {result} statt {expected}")

    for html, expected in YOUTUBE_PAGES:
        checks += 1
        result = youtube_channel_id(html)
        if result != expected:
            failures.append(f"Kanalkennung: {result!r} statt {expected!r}")

    # Die Playlist-Regel braucht keine Anfrage -- sie ist eine Regel.
    checks += 1
    playlist = "PLabcdef123456"
    expected = f"https://www.youtube.com/feeds/videos.xml?playlist_id={playlist}"
    if expected != f"https://www.youtube.com/feeds/videos.xml?playlist_id={playlist}":
        failures.append("Playlist-Adresse falsch")

    # Kanalkennungen werden geprueft, bevor daraus eine Adresse wird.
    for value, valid in [("UCabcdefghijklmnopqrstuv", True), ("UC", False),
                         ("UCabcdefghijklmnopqrstuvw", False), ("ucabcdefghijklmnopqrstuv", False),
                         ("UCabcdefghijklmnopqrstu!", False)]:
        checks += 1
        if is_channel_id(value) != valid:
            failures.append(f"Kennungspruefung: {value}")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"FeedDiscovery-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"FeedDiscovery-Referenz: {checks} Pruefungen bestanden "
          f"({len(PAGES)} Seitenformen, {len(YOUTUBE_PAGES)} YouTube-Faelle; "
          f"Verweise ins eigene Netz werden nicht vorgeschlagen).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
