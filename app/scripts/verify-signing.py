#!/usr/bin/env python3
"""Prüft, ob eine signierte App die Berechtigungen trägt, die PodcastAI braucht.

Aufruf:  verify-signing.py <PodcastAI.app|.ipa|.pkg> [--platform ios|mac|tv] [--distribution]

Warum es das gibt: Fehlt der fertigen App die Berechtigung für Private Cloud
Compute oder für iCloud, baut und startet sie ohne Fehler. Erst auf dem Gerät
meldet sie „nicht verfügbar“, und die Arbeit steht. Das Skript liest die
Berechtigungen aus der tatsächlich signierten App, nicht aus der Datei im
Projekt, und bricht mit Fehlercode 1 ab, wenn etwas fehlt oder ein Debug-Rest
im Release steckt. `upload-testflight.sh` exportiert jede App vor dem Upload
einmal lokal und ruft das Skript mit `--distribution` auf dem Export auf.

Die Uhr-App hat kein eigenes Archiv; sie steckt in der iPhone-App und wird
dort mitgeprüft.
"""
import argparse
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

ICLOUD_CONTAINER = "iCloud.com.godmodeai.podcastai"
APP_GROUP = "group.com.godmodeai.podcastai"

# Berechtigung -> erwarteter Wert; None heißt „muss vorhanden sein“.
REQUIRED = {
    "ios": {
        "com.apple.developer.private-cloud-compute": True,
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [ICLOUD_CONTAINER],
        "com.apple.security.application-groups": [APP_GROUP],
        "aps-environment": ("development", "production"),
    },
    "mac": {
        "com.apple.developer.private-cloud-compute": True,
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [ICLOUD_CONTAINER],
        "com.apple.security.application-groups": [APP_GROUP],
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.developer.aps-environment": ("development", "production"),
    },
    # Der Fernseher ist ein reiner Player: nur der Abgleich, kein Push, keine KI.
    "tv": {
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [ICLOUD_CONTAINER],
    },
}

# Dürfen in einem Release nicht stehen.
FORBIDDEN = {"com.apple.security.get-task-allow": "Debugging ist im Release an"}


def unpacked(path: Path, into: Path) -> Path:
    """Die App aus einem Export: .ipa (iPhone, Apple TV) oder .pkg (Mac)."""
    if path.suffix == ".ipa":
        subprocess.run(["ditto", "-x", "-k", str(path), str(into)], check=True)
    elif path.suffix == ".pkg":
        # pkgutil legt das Ziel selbst an und verlangt, dass es noch fehlt.
        into = into / "pkg"
        subprocess.run(["pkgutil", "--expand-full", str(path), str(into)], check=True)
    else:
        return path
    apps = sorted(into.glob("**/Payload/*.app"))
    if not apps:
        sys.exit(f"Keine App gefunden in {path}")
    return apps[0]


def platform_of(app: Path) -> str:
    # Eine Mac-App hat Contents/, iPhone und Apple TV legen Info.plist neben die Binärdatei.
    if (app / "Contents").is_dir():
        return "mac"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    return "tv" if "AppleTVOS" in info.get("CFBundleSupportedPlatforms", []) else "ios"


def entitlements(path: Path) -> dict:
    out = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(path)],
        capture_output=True,
    )
    data = out.stdout
    if not data:
        sys.exit(f"Keine Berechtigungen gelesen aus {path}:\n{out.stderr.decode(errors='replace')}")
    # Neuere codesign-Fassungen stellen dem Plist eine Längenkennung voran.
    start = data.find(b"<?xml")
    return plistlib.loads(data[start:] if start >= 0 else data)


def contains(actual, expected) -> bool:
    if isinstance(expected, tuple):  # einer von mehreren erlaubten Werten
        return actual in expected
    if isinstance(expected, list):
        return isinstance(actual, list) and all(item in actual for item in expected)
    return actual == expected


def check(app: Path, platform: str, distribution: bool = False) -> list[str]:
    found = entitlements(app)
    problems = []
    if distribution and platform != "tv":
        # Im Archiv steckt noch die Entwicklungssignatur; erst der Export signiert
        # für den Vertrieb. Dort muss die Push-Umgebung „production“ heißen.
        key = "aps-environment" if platform == "ios" else "com.apple.developer.aps-environment"
        if found.get(key) != "production":
            problems.append(f"{key} = {found.get(key)!r}, erwartet 'production' im Vertrieb")
    for key, expected in REQUIRED[platform].items():
        if key not in found:
            problems.append(f"fehlt: {key}")
        elif expected is not None and not contains(found[key], expected):
            problems.append(f"falscher Wert: {key} = {found[key]!r}, erwartet {expected!r}")
    for key, why in FORBIDDEN.items():
        if found.get(key):
            problems.append(f"{key}: {why}")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path,
                        help="signierte .app (etwa im .xcarchive unter Products/Applications) oder ein Export als .ipa/.pkg")
    parser.add_argument("--platform", choices=["ios", "mac", "tv"], default=None)
    parser.add_argument("--distribution", action="store_true",
                        help="auch prüfen, dass die Push-Umgebung production heißt (für den exportierten Stand)")
    args = parser.parse_args()

    if not args.app.exists():
        sys.exit(f"Nicht gefunden: {args.app}")

    with tempfile.TemporaryDirectory() as scratch:
        app = unpacked(args.app, Path(scratch))
        platform = args.platform or platform_of(app)
        problems = check(app, platform, args.distribution)

        # Die Uhr-App steckt in der iPhone-App und braucht ihre eigene Signatur.
        watch = list((app / "Watch").glob("*.app")) if platform == "ios" else []
        for item in watch:
            if subprocess.run(["codesign", "--verify", "--strict", str(item)], capture_output=True).returncode != 0:
                problems.append(f"Uhr-App nicht gültig signiert: {item.name}")

    name = args.app.name
    if problems:
        print(f"{name} ({platform}): Signatur unvollständig")
        for problem in problems:
            print(f"  - {problem}")
        sys.exit(1)
    extra = f", Uhr-App {watch[0].name} gültig" if watch else ""
    print(f"{name} ({platform}): Berechtigungen vollständig{extra}")


if __name__ == "__main__":
    main()
