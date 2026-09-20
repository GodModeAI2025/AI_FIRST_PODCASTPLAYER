"""
Referenzmodell zu PodcastAICore/NetworkDestination.swift.

Das Vorgaengermodell (redirectguard_reference.py) pruefte eine Sperrliste:
"ist dieser Host privat?". Diese Frage ist nicht zu gewinnen, weil ein Host
auf beliebig viele Arten geschrieben werden kann und jede Schreibweise
einzeln in die Liste muss.

Die Swift-Fassung stellt die Frage deshalb andersherum: eine Zieladresse ist
nur zugelassen, wenn sie http/https ist, einen Standardport benutzt, keine
Zugangsdaten mitbringt und einen *Namen* hat, der keine IP-Schreibweise und
kein lokaler Name ist. Ein Podcast-Enclosure hat keinen Grund, eine nackte
IP zu sein.

Geprueft wird hier gegen ein unabhaengiges Orakel: Pythons `ipaddress`
zusammen mit `socket.inet_aton`-Semantik (die 127.1, oktal und hex genauso
aufloest wie der Netzwerkstack des Systems). Der Nachweis lautet:

    Orakel sagt "das ist eine IP"       ==> Swift-Modell lehnt ab
    Orakel sagt "das ist privat/lokal"  ==> Swift-Modell lehnt ab

Die erste Aussage ist die staerkere: sie deckt auch Schreibweisen ab, die
noch niemandem eingefallen sind.
"""
import ipaddress
import socket
import sys
from urllib.parse import urlsplit

LOCAL_SUFFIXES = (".localhost", ".local", ".internal", ".home", ".lan", ".intranet")


# --------------------------------------------------------------------------
# Portierung der Swift-Fassung, Zeile fuer Zeile.
# --------------------------------------------------------------------------

def looks_like_ip_literal(host):
    """Portierung von NetworkDestination.looksLikeIPLiteral."""
    value = host
    if value.startswith("[") and value.endswith("]"):
        return True
    if ":" in value:
        return True
    if value.endswith("."):
        value = value[:-1]
    without = value.replace(".", "")
    if not without:
        return False
    if without.isdigit():
        return True
    if value.lower().startswith("0x") and all(
        c in "0123456789abcdefABCDEF" for c in without[2:]
    ):
        return True
    return False


def is_local_name(host):
    """Portierung von NetworkDestination.isLocalName."""
    value = host
    if value.endswith("."):
        value = value[:-1]
    if value == "localhost":
        return True
    if any(value.endswith(s) for s in LOCAL_SUFFIXES):
        return True
    return "." not in value


def validate(url):
    """Portierung von NetworkDestination.validate. Gibt None zurueck oder den Grund."""
    parts = urlsplit(url)
    scheme = (parts.scheme or "").lower()
    if not scheme:
        return "unsupportedScheme"
    if scheme not in ("http", "https"):
        return "unsupportedScheme"
    if parts.username or parts.password:
        return "embeddedCredentials"
    try:
        host = (parts.hostname or "").lower()
    except ValueError:
        return "missingHost"
    if not host:
        return "missingHost"
    try:
        port = parts.port
    except ValueError:
        return "unsupportedPort"
    if port is not None and port not in (80, 443):
        return "unsupportedPort"
    if looks_like_ip_literal(host):
        return "ipLiteral"
    if is_local_name(host):
        return "localOrPrivateName"
    return None


# --------------------------------------------------------------------------
# Unabhaengiges Orakel.
# --------------------------------------------------------------------------

def oracle_address(host):
    """Loest den Host als IP auf, in *irgendeiner* Schreibweise, oder None.

    `socket.inet_aton` versteht dieselben Kurzformen wie der Netzwerkstack:
    "127.1", "0177.0.0.1", "0x7f000001", "2130706433". Genau die Formen,
    gegen die eine Sperrliste verliert.
    """
    stripped = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    try:
        return ipaddress.IPv6Address(stripped)
    except ValueError:
        pass
    try:
        return ipaddress.IPv4Address(socket.inet_aton(host))
    except (OSError, ValueError, ipaddress.AddressValueError):
        return None


def oracle_is_private(address):
    return (address.is_private or address.is_loopback or address.is_link_local
            or address.is_reserved or address.is_unspecified)


# --------------------------------------------------------------------------
# Pruefung
# --------------------------------------------------------------------------

LOCALHOST_SPELLINGS = [
    "127.0.0.1", "127.1", "127.0.1", "2130706433", "0x7f000001",
    "0177.0.0.1", "017700000001", "127.000.000.001", "127.0.0.1.",
    "0.0.0.0", "0", "[::1]", "::1", "[::ffff:127.0.0.1]",
]

PRIVATE_SPELLINGS = [
    "10.0.0.5", "192.168.1.1", "172.16.0.1", "172.31.255.254",
    "169.254.169.254",          # Metadatendienst mehrerer Cloud-Anbieter
    "[fd00::1]", "fd00::1", "[fe80::1]",
    "3232235777",               # 192.168.1.1 dezimal
    "0xa000005",                # 10.0.0.5 hexadezimal
]

LOCAL_NAMES = [
    "localhost", "LOCALHOST", "localhost.", "app.localhost",
    "nas.local", "printer.local", "router", "nas", "fritz.box.internal",
    "server.lan", "wiki.intranet", "hub.home",
]

# Adressen, die zugelassen sein muessen -- sonst ist die Regel unbrauchbar.
MUST_ACCEPT = [
    "https://feeds.example.com/podcast.xml",
    "http://example.org/feed",
    "https://cdn.example.co.uk:443/audio/1.mp3",
    "http://media.example.com:80/1.mp3",
    "https://xn--bcher-kva.example/feed",       # Punycode
    "https://example.com./feed",                # absoluter Name mit Punkt
]

MUST_REJECT_URLS = [
    "file:///etc/passwd",
    "ftp://example.com/feed",
    "javascript:alert(1)",
    "data:text/xml,<rss/>",
    "https://user:pass@example.com/feed",
    "https://example.com:11434/api/tags",
    "http://example.com:8080/feed",
    "https:///feed",
]


def main():
    checks = 0
    failures = []

    # 1. Jede Schreibweise von localhost und jede private Adresse faellt durch.
    for host in LOCALHOST_SPELLINGS + PRIVATE_SPELLINGS:
        checks += 1
        if validate(f"http://{host}/x") is None:
            failures.append(f"nicht abgelehnt: {host}")

    # 2. Lokale Namen fallen durch.
    for host in LOCAL_NAMES:
        checks += 1
        if validate(f"http://{host}/x") is None:
            failures.append(f"lokaler Name nicht abgelehnt: {host}")

    # 3. Orakelabgleich: was das System als IP auflöst, lehnt das Modell ab.
    #    Das ist die Aussage, die ueber die Liste oben hinausgeht.
    for host in LOCALHOST_SPELLINGS + PRIVATE_SPELLINGS + [
        "8.8.8.8", "1.1.1.1", "[2606:4700::1111]", "134744072",
    ]:
        address = oracle_address(host)
        if address is None:
            continue
        checks += 1
        if validate(f"http://{host}/x") is None:
            failures.append(
                f"Orakel sagt IP ({address}), Modell laesst durch: {host}")
        if oracle_is_private(address):
            checks += 1
            if validate(f"https://{host}/x") is None:
                failures.append(
                    f"Orakel sagt privat ({address}), Modell laesst durch: {host}")

    # 4. Unzulaessige Adressformen.
    for url in MUST_REJECT_URLS:
        checks += 1
        if validate(url) is None:
            failures.append(f"nicht abgelehnt: {url}")

    # 5. Echte Feedadressen kommen durch -- sonst waere die Regel zu scharf.
    for url in MUST_ACCEPT:
        checks += 1
        reason = validate(url)
        if reason is not None:
            failures.append(f"faelschlich abgelehnt ({reason}): {url}")

    # 6. Bekannte Grenze, ausdruecklich festgehalten: geprueft wird der Name,
    #    verbunden wird zur aufgeloesten Adresse. Ein Name, der auf 127.0.0.1
    #    zeigt, kommt durch. Das ist DNS-Rebinding und hier nicht geloest.
    checks += 1
    if validate("http://rebind.example.com/x") is not None:
        failures.append("Erwartung verschoben: ein normaler Name muss durchkommen")

    if failures:
        for line in failures:
            print(f"  FEHLER: {line}")
        print(f"NetworkDestination-Referenz: {len(failures)} von {checks} Pruefungen fehlgeschlagen.")
        return 1

    print(f"NetworkDestination-Referenz: {checks} Pruefungen bestanden "
          f"({len(LOCALHOST_SPELLINGS)} localhost-Schreibweisen, "
          f"{len(PRIVATE_SPELLINGS)} private Adressen, "
          f"{len(LOCAL_NAMES)} lokale Namen, gegen ipaddress/inet_aton abgeglichen).")
    print("  Bekannte Grenze: DNS-Rebinding ist nicht abgedeckt "
          "(geprueft wird der Name, verbunden wird zur Adresse).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
