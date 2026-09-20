"""
Referenzmodell zu PodcastAIExport/MarkdownExporter.swift.

Zwei Zusagen werden geprueft:
  1. Kein privater Feedtoken gelangt in einen Export.
  2. Fremder Text kann die Struktur des Exports nicht zerlegen.
"""
import random
import string
from urllib.parse import urlparse

SPECIALS = set("\\`*_[]()#|<>")


def escape_specials(text):
    """Portierung: Steuerzeichen (ausser \n) werden zu Leerzeichen, Sonderzeichen maskiert."""
    out = []
    for c in text:
        if c != "\n" and (ord(c) < 32 or ord(c) == 127):
            out.append(" ")
        elif c in SPECIALS:
            out.append("\\" + c)
        else:
            out.append(c)
    return "".join(out)


def escape_inline(text):
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    single = " ".join(p.strip() for p in normalized.split("\n") if p.strip())
    return escape_specials(single)


def escape_block(text):
    # Swift .newlines trennt an \n, \r, \r\n, U+0085, U+2028, U+2029 --
    # hier genuegt die Normalisierung auf \n fuer den Vergleich.
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(escape_specials(line) for line in normalized.split("\n"))


def safe_source_link(url):
    """Portierung von SafeSourceLink.init?(publicURL:)."""
    if not url:
        return None
    u = urlparse(url)
    if u.scheme not in ("http", "https"):
        return None
    if u.username or u.password:
        return None
    if u.query or u.fragment:
        return None
    if not u.hostname:
        return None
    return url


def main():
    rng = random.Random(24680)
    checks = 0

    # --- 1. Private Adressen kommen nicht durch ---
    must_reject = [
        "https://user:secret@feed.example.com/rss.xml",       # Zugangsdaten
        "https://feed.example.com/rss.xml?token=abc123",      # Token im Query
        "https://feed.example.com/rss.xml#section",           # Fragment
        "file:///Users/me/private.m4a",                       # lokale Datei
        "javascript:alert(1)",
        "data:text/html,<script>",
        "",
        None,
    ]
    for url in must_reject:
        assert safe_source_link(url) is None, f"haette abgelehnt werden muessen: {url}"
        checks += 1

    must_accept = [
        "https://example.com/podcast/folge-147",
        "http://example.org/ep/1",
    ]
    for url in must_accept:
        assert safe_source_link(url) == url, f"haette akzeptiert werden muessen: {url}"
        checks += 1

    # Ein Token im PFAD wird nicht durch Entfernen des Querystrings sicher.
    # Die strenge Pruefung laesst ihn durch -- deshalb ist die Zusage:
    # ein Link entsteht nur aus einer AUSDRUECKLICH als oeffentlich
    # markierten Adresse, nicht aus der Feed-URL.
    path_token = "https://feed.example.com/abc123secret/rss.xml"
    assert safe_source_link(path_token) == path_token
    checks += 1

    # --- 2. Fremder Text zerlegt die Struktur nicht ---
    for _ in range(30000):
        raw = "".join(rng.choice(string.printable) for _ in range(rng.randint(0, 200)))

        inline = escape_inline(raw)
        # Keine Zeilenumbrueche -- eine Ueberschrift bleibt eine Zeile.
        assert "\n" not in inline and "\r" not in inline, "Umbruch in Inline-Text"
        checks += 1

        # Jedes Sonderzeichen ist maskiert.
        i = 0
        while i < len(inline):
            c = inline[i]
            if c == "\\":
                i += 2
                continue
            assert c not in SPECIALS, f"unmaskiertes {c!r} in {inline!r}"
            i += 1
        checks += 1

        block = escape_block(raw)
        # Zeilenzahl bleibt erhalten -- Absaetze gehen nicht verloren.
        normalized = raw.replace("\r\n", "\n").replace("\r", "\n")
        assert block.count("\n") == normalized.count("\n"), "Zeilen verloren"
        # Ausser dem Zeilenumbruch bleibt kein Steuerzeichen uebrig.
        assert all(c == "\n" or (ord(c) >= 32 and ord(c) != 127) for c in block), \
            "Steuerzeichen im Export"
        checks += 2

    # --- Konkrete Angriffsfaelle ---
    cases = [
        ("Folge [147](https://evil.invalid)", "eingeschleuster Link"),
        ("Titel\n# Gefaelschte Ueberschrift", "eingeschleuste Ueberschrift"),
        ("a | b | c", "zerlegte Tabelle"),
        ("<script>alert(1)</script>", "eingebettetes HTML"),
        ("```\nrm -rf /\n```", "eingeschleuster Codeblock"),
    ]
    def has_unescaped(text, ch):
        """Kommt ch im Ergebnis vor, ohne dass ein Backslash davorsteht?"""
        i = 0
        while i < len(text):
            if text[i] == "\\":
                i += 2
                continue
            if text[i] == ch:
                return True
            i += 1
        return False

    for raw, why in cases:
        out = escape_inline(raw)
        # Entscheidend ist nicht, ob die Zeichenfolge noch vorkommt, sondern
        # ob sie noch WIRKT. "\\<script" rendert als Text, nicht als HTML.
        for ch in "<>[]()#`|*_":
            assert not has_unescaped(out, ch), f"{why}: unmaskiertes {ch!r} in {out!r}"
        assert not out.lstrip().startswith("#"), why
        checks += 1

    print(f"MarkdownExport-Referenz: {checks} Pruefungen bestanden (30000 Zufallstexte).")


if __name__ == "__main__":
    main()
