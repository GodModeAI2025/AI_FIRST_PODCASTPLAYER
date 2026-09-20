#!/usr/bin/env python3
"""
Statische Konsistenzpruefung ueber den Swift-Code.

Kein Ersatz fuer einen Compiler, aber sie findet die Fehlerklassen, die beim
Schreiben ohne Compiler tatsaechlich entstehen: unausgeglichene Klammern,
doppelt deklarierte Typen, Verweise auf Typen, die es nicht gibt, und
Dateien, die einen Guard oeffnen und nicht schliessen.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT = sorted(ROOT.rglob("*.swift"))

# In Swift eingebaute oder aus Apple-Frameworks stammende Namen.
KNOWN = {
    # Standardbibliothek
    "String","Int","Int64","Int32","UInt8","UInt64","Double","Bool","Date","UUID","URL","Data",
    "Array","Set","Dictionary","Result","Error","Void","Any","AnyObject","Optional","Character",
    "Task","TimeInterval","IndexSet","Range","ClosedRange","Comparable","Hashable","Equatable",
    "Codable","Encodable","Decodable","Sendable","Identifiable","CustomStringConvertible",
    "CaseIterable","Encoder","Decoder","LocalizedError","AsyncStream","AsyncThrowingStream",
    "AsyncSequence","CancellationError","NSObject","NSNumber","NSError","ObjectIdentifier",
    # Foundation
    "Locale","Calendar","TimeZone","DateFormatter","ISO8601DateFormatter","CharacterSet",
    "FileManager","FileHandle","URLSession","URLSessionConfiguration","URLRequest","URLComponents",
    "URLQueryItem","HTTPURLResponse","URLResponse","XMLParser","XMLParserDelegate","UserDefaults",
    "NotificationCenter","Notification","Bundle","ProcessInfo","OperationQueue","NSObjectProtocol",
    "URLSessionTask","URLSessionTaskDelegate","URLSessionDownloadTask","SHA256","Insecure",
    "LocalizedStringResource","NSTemporaryDirectory","NSHomeDirectory",
    # AVFoundation / CoreMedia
    "AVAudioFile","AVAudioFormat","AVAudioPCMBuffer","AVAudioConverter","AVAudioFrameCount",
    "AVAudioFramePosition","AVPlayer","AVQueuePlayer","AVPlayerItem","AVAudioEngine","AVAudioSession",
    "CMTime","CMTimeRange","CMTimeValue","CMTimeScale",
    # Speech
    "SpeechAnalyzer","SpeechTranscriber","AnalyzerInput","AssetInventory","SFSpeechRecognizer",
    # FoundationModels
    "SystemLanguageModel","LanguageModelSession","Generable","Guide",
    # SwiftData
    "Model","ModelContainer","ModelContext","ModelConfiguration","Schema","FetchDescriptor",
    "SortDescriptor","Predicate","ModelActor","Attribute","Relationship","Index",
    # SwiftUI
    "View","App","Scene","WindowGroup","Settings","NavigationStack","NavigationSplitView",
    "TabView","Tab","List","Section","Form","Text","Image","Button","Label","HStack","VStack",
    "ZStack","ScrollView","LazyVStack","Spacer","Divider","Picker","TextField","Toggle","Stepper",
    "ForEach","State","Binding","Environment","EnvironmentObject","Observable","Bindable",
    "ContentUnavailableView","LabeledContent","RoundedRectangle","Capsule","Color","Font",
    "CommandGroup","ToolbarItem","EdgeInsets","DisplayRepresentation","TypeDisplayRepresentation",
    "IntentDescription","IntentResult","ProvidesDialog","AppIntent","AppEntity","EntityQuery",
    "AppShortcut","AppShortcutsProvider","Dependency","Parameter","MainActor","NSWorkspace",
    "SecTaskCreateFromSelf","Never","PackageDescription","Package","NavigationLink",
    "CDATABlock","Test","Suite","Issue","Testing",
}

declared, extended, referenced, problems = {}, {}, {}, []
imported = set()

DECL = re.compile(
    r"^\s*(?:public |internal |private |fileprivate |final |open )*"
    r"(?:actor|class|struct|enum|protocol|typealias)\s+([A-Z][A-Za-z0-9_]*)", re.M)
EXT = re.compile(r"^\s*extension\s+([A-Z][A-Za-z0-9_]*)", re.M)
USE = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")

for path in SWIFT:
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)

    # Klammern ausgleichen. Reihenfolge wichtig: mehrzeilige Strings zuerst,
    # sonst zerlegt die einzeilige Regel sie und laesst Klammern zurueck.
    stripped = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    stripped = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', stripped)
    stripped = re.sub(r"//[^\n]*", "", stripped)
    stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.S)
    for open_ch, close_ch, name in (("{", "}", "geschweifte"), ("(", ")", "runde"), ("[", "]", "eckige")):
        diff = stripped.count(open_ch) - stripped.count(close_ch)
        if diff:
            problems.append(f"{rel}: {abs(diff)} {'zu viele' if diff > 0 else 'fehlende'} {name} Klammern")

    # #if / #endif ausgleichen
    ifs = len(re.findall(r"^\s*#if\b", text, re.M))
    endifs = len(re.findall(r"^\s*#endif\b", text, re.M))
    if ifs != endifs:
        problems.append(f"{rel}: {ifs} #if, aber {endifs} #endif")

    for name in DECL.findall(text):
        declared.setdefault(name, []).append(str(rel))
    for name in EXT.findall(text):
        extended.setdefault(name, []).append(str(rel))

    # Importierte Module und eigene Modulnamen sind keine Typverweise.
    imported.update(re.findall(r"^\s*(?:@_exported\s+)?import\s+([A-Za-z0-9_]+)", text, re.M))
    imported.update(re.findall(r"canImport\(([A-Za-z0-9_]+)\)", text))

    # Nur ausserhalb von Strings und Kommentaren zaehlen.
    for name in USE.findall(stripped):
        referenced.setdefault(name, set()).add(str(rel))

# Doppelte Deklarationen im selben Modul.
for name, paths in declared.items():
    modules = {p.split("/")[3] if p.startswith("Packages/") and len(p.split("/")) > 3 else p.split("/")[1]
               for p in paths}
    if len(paths) > 1 and len(modules) == 1:
        problems.append(f"Typ '{name}' mehrfach deklariert: {', '.join(paths)}")

# Verweise auf unbekannte Typen.
unknown = {}
# Generische Parameter und geschachtelte Typen, die die Heuristik nicht sieht.
NESTED = {"Subject", "Self", "Element", "UnavailableReason", "Continuation",
          "Availability", "Error", "Failure", "Success", "Output", "Result"}

for name, paths in referenced.items():
    if name in declared or name in KNOWN or name in imported or name in NESTED:
        continue
    if name.startswith("AV") or name.startswith("NS") or name.startswith("CM"):
        continue
    # Aufzaehlungsfaelle, Methoden und Eigenschaften filtern wir ueber die
    # Heuristik heraus, dass ein Typ irgendwo deklariert sein muesste.
    unknown[name] = sorted(paths)

print(f"Swift-Dateien: {len(SWIFT)}")
print(f"Deklarierte Typen: {len(declared)}")
print(f"Erweiterungen: {len(extended)}")
print(f"Importierte Module/Frameworks: {len(imported)}")
print(f"Unaufgeloeste Bezeichner: {len(unknown)}")

if unknown:
    print("\n-- Zu pruefen (koennen Enum-Faelle, Modulnamen oder echte Fehler sein) --")
    for name in sorted(unknown)[:60]:
        print(f"  {name:36s} {unknown[name][0]}")

if problems:
    print("\n-- BEFUNDE --")
    for p in problems:
        print(f"  {p}")
    sys.exit(1)

print("\nKeine Klammern-, Guard- oder Doppeldeklarationsfehler gefunden.")
