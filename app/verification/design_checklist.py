#!/usr/bin/env python3
"""
Prueft die SwiftUI-Oberflaechen gegen die Apple-Designregeln.

Nicht alles ist automatisch pruefbar -- Kontrastverhaeltnisse und ob eine
Hierarchie wirklich traegt, sieht man nur am Geraet. Pruefbar ist aber, was
erfahrungsgemaess still verrutscht: Tab-Anzahl, Zahlen statt Tokens,
Schaltflaechen ohne Beschriftung, Bewegung ohne Ruecksicht auf
Reduce Motion, und Glas auf Glas.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
VIEWS = sorted((ROOT / "Apps").rglob("*.swift"))

findings, notes = [], []


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


# --- 1. Tab Bar: drei bis fuenf Eintraege ---------------------------------
ios = (ROOT / "Apps/PodcastAI/PodcastAIApp.swift").read_text()
tabs = re.findall(r"^\s*Tab\(\"", strip_comments(ios), re.M)
if not (3 <= len(tabs) <= 5):
    findings.append(f"Tab Bar hat {len(tabs)} Eintraege; erlaubt sind 3 bis 5")
else:
    notes.append(f"Tab Bar: {len(tabs)} Eintraege")

# Aktiver Such-Tab (WWDC25)
if 'role: .search' in ios:
    notes.append("Such-Tab vorhanden")
else:
    findings.append("Kein Tab mit role: .search -- die Suche hat seit WWDC25 einen eigenen Platz")

# --- 2. Abstaende: Tokens statt Zahlen ------------------------------------
magic = []
for path in VIEWS:
    if path.name == "DesignSystem.swift":
        continue
    body = strip_comments(path.read_text())
    for match in re.finditer(r"\.padding\((?:\.[a-z]+,\s*)?(\d+)\)", body):
        magic.append(f"{path.name}: .padding({match.group(1)})")
    for match in re.finditer(r"spacing:\s*(\d+)\)", body):
        magic.append(f"{path.name}: spacing: {match.group(1)}")
if magic:
    findings.append(f"{len(magic)} Abstaende als Zahl statt als Token: "
                    + ", ".join(magic[:5]) + ("" if len(magic) <= 5 else " ..."))
else:
    notes.append("Alle Abstaende ueber Design.Spacing")

# --- 3. Eckenradien als Zahl ----------------------------------------------
radii = []
for path in VIEWS:
    if path.name == "DesignSystem.swift":
        continue
    for match in re.finditer(r"cornerRadius:\s*(\d+)", strip_comments(path.read_text())):
        radii.append(f"{path.name}: {match.group(1)}")
if radii:
    findings.append(f"{len(radii)} Eckenradien als Zahl statt als Token: " + ", ".join(radii[:5]))
else:
    notes.append("Alle Eckenradien ueber Design.Radius")

# --- 4. Schaltflaechen mit nur einem Symbol brauchen eine Beschriftung -----
unlabeled = []
for path in VIEWS:
    body = path.read_text()
    # Button { ... Image(systemName:) ... } ohne accessibilityLabel im Umkreis
    for match in re.finditer(r"Button\s*(?:\(action:[^)]*\))?\s*\{(.{0,400}?)\}\s*\n", body, re.S):
        block = match.group(1)
        if "Image(systemName:" in block and "Text(" not in block and "Label(" not in block:
            tail = body[match.end():match.end() + 400]
            if "accessibilityLabel" not in tail and "accessibilityLabel" not in block:
                line = body[:match.start()].count("\n") + 1
                unlabeled.append(f"{path.name}:{line}")
if unlabeled:
    findings.append(f"{len(unlabeled)} Symbol-Schaltflaechen ohne accessibilityLabel: "
                    + ", ".join(unlabeled[:5]))
else:
    notes.append("Alle Symbol-Schaltflaechen beschriftet")

# --- 5. Treffflaechen ------------------------------------------------------
#
# Nicht jede Schaltflaeche bemisst die App selbst. Was in einer Wischaktion,
# einem Bestaetigungsdialog, einem Hinweis oder einer Werkzeugleiste steht,
# legt das System aus -- dort eine eigene Mindestflaeche zu verlangen waere
# nicht nur ueberfluessig, sondern falsch.
#
# Die Unterscheidung steht hier, weil eine Regel, die grundlos warnt,
# irgendwann ignoriert wird. Dann faellt der echte Fall mit durch.
SYSTEM_SIZED = ("swipeActions", "confirmationDialog", "alert", "toolbar",
                "contextMenu", "ToolbarItem")


def system_sized_ranges(body):
    """Grobe Spannen der Modifier, die ihre Schaltflaechen selbst bemessen."""
    spans = []
    for name in SYSTEM_SIZED:
        for match in re.finditer(re.escape(name), body):
            # Bis zum Ende des zugehoerigen Blocks, hoechstens 1200 Zeichen --
            # genug fuer einen Dialog, zu wenig, um eine ganze Ansicht zu
            # verschlucken.
            spans.append((match.start(), match.start() + 1200))
    return spans


for path in VIEWS:
    body = strip_comments(path.read_text())
    spans = system_sized_ranges(body)
    buttons = 0
    for match in re.finditer(r"\bButton\s*[({]", body):
        if any(start <= match.start() < end for start, end in spans):
            continue
        buttons += 1
    targets = body.count("tappableArea()") + body.count("minHeight: Design.minimumTapTarget")
    if buttons >= 3 and targets == 0:
        findings.append(f"{path.name}: {buttons} Schaltflaechen, aber keine Mindesttrefflaeche gesetzt")

# --- 6. Bewegung respektiert Reduce Motion --------------------------------
for path in VIEWS:
    body = strip_comments(path.read_text())
    if "withAnimation(" in body or "repeatForever" in body:
        if "accessibilityReduceMotion" not in body and "respectingReduceMotion" not in body:
            findings.append(f"{path.name}: animiert ohne Ruecksicht auf Reduce Motion")

# --- 7. Kein Glas auf Glas -------------------------------------------------
for path in VIEWS:
    body = strip_comments(path.read_text())
    for match in re.finditer(r"glassEffect", body):
        window = body[max(0, match.start() - 300):match.start()]
        if "glassEffect" in window:
            line = body[:match.start()].count("\n") + 1
            findings.append(f"{path.name}:{line}: Glas auf Glas gestapelt")

glass_count = sum(strip_comments(p.read_text()).count("glassEffect") for p in VIEWS)
notes.append(f"Liquid Glass an {glass_count} Stellen (nur Navigationsebene)")

# --- 8. Farbe nie allein als Traeger --------------------------------------
color_only = []
for path in VIEWS:
    body = strip_comments(path.read_text())
    for match in re.finditer(r"foregroundStyle\(\.(orange|red|green)\)", body):
        window = body[max(0, match.start() - 350):match.start()]
        if "systemImage" not in window and "Image(systemName" not in window:
            line = body[:match.start()].count("\n") + 1
            color_only.append(f"{path.name}:{line}")
if color_only:
    findings.append(f"{len(color_only)} Stellen tragen Bedeutung allein ueber Farbe: "
                    + ", ".join(color_only[:5]))
else:
    notes.append("Farbe nirgends alleiniger Bedeutungstraeger")

# --- 9. Leere Zustaende ----------------------------------------------------
empty = sum(strip_comments(p.read_text()).count("ContentUnavailableView") for p in VIEWS)
notes.append(f"{empty} erklaerte leere Zustaende")

# --- Ausgabe --------------------------------------------------------------
print(f"Oberflaechendateien: {len(VIEWS)}")
for note in notes:
    print(f"  ok   {note}")

if findings:
    print("\n-- BEFUNDE --")
    for f in findings:
        print(f"  {f}")
    sys.exit(1)

print("\nDesign-Checkliste bestanden.")
