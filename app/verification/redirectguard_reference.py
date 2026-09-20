"""
Referenzmodell zu PodcastAIMedia/MediaDownloader.swift (RedirectGuard).

Ein Feed ist fremder Input. Er darf die App nicht als Sprungbrett ins
eigene Netz benutzen. Geprueft wird, welche Weiterleitungsziele abgelehnt
werden muessen.
"""


def is_local_or_private(host):
    """Portierung von RedirectGuard.isLocalOrPrivate."""
    h = host.lower()
    if h in ("localhost", "::1") or h.endswith(".local"):
        return True
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    # IPv6 Unique Local (fc00::/7) und Link-Local (fe80::/10)
    if ":" in h:
        first = h.split(":")[0]
        if first.startswith(("fc", "fd", "fe8", "fe9", "fea", "feb")):
            return True
        if h in ("::1", "::"):
            return True
        return False
    parts = h.split(".")
    if len(parts) != 4:
        return False
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return False
    if not all(0 <= n <= 255 for n in nums):
        return False
    a, b = nums[0], nums[1]
    if a == 0:            # 0.0.0.0/8 -- routet vielerorts auf localhost
        return True
    if a == 127:
        return True
    if a == 10:
        return True
    if (a, b) == (169, 254):
        return True
    if (a, b) == (192, 168):
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    return False


def main():
    must_reject = [
        "localhost", "LOCALHOST", "printer.local",
        "127.0.0.1", "127.1.2.3",
        "0.0.0.0",
        "10.0.0.5", "10.255.255.255",
        "192.168.1.1",
        "172.16.0.1", "172.20.5.5", "172.31.255.254",
        "169.254.169.254",          # Cloud-Metadatendienst
        "::1", "[::1]",
        "fd00::1", "fc00::1", "[fd12:3456::1]",
        "fe80::1",
    ]
    must_accept = [
        "example.com", "cdn.example.org",
        "8.8.8.8", "1.1.1.1",
        "172.15.0.1", "172.32.0.1",   # knapp ausserhalb des privaten Bereichs
        "192.169.1.1", "11.0.0.1",
        "2606:4700::1111",            # oeffentliches IPv6
    ]

    for host in must_reject:
        assert is_local_or_private(host), f"haette abgelehnt werden muessen: {host}"
    for host in must_accept:
        assert not is_local_or_private(host), f"haette akzeptiert werden muessen: {host}"

    print(f"RedirectGuard-Referenz: {len(must_reject) + len(must_accept)} Adressen geprueft "
          f"({len(must_reject)} abgelehnt, {len(must_accept)} zugelassen).")


if __name__ == "__main__":
    main()
