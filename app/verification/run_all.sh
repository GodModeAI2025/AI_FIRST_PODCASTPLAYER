#!/usr/bin/env bash
# Faehrt alle ausfuehrbaren Referenzmodelle zur PodcastAI-Kernlogik.
#
# Diese Umgebung hat keinen Swift-Compiler (download.swift.org ist per
# Netzwerkpolicy gesperrt). Die Referenzmodelle sind Zeile fuer Zeile aus dem
# Swift-Code portiert und werden gegen Brute-Force-Modelle geprueft. Das belegt
# die Logik, nicht die Swift-Syntax. Ein Xcode-Build bleibt offen.
set -euo pipefail
cd "$(dirname "$0")"
python3 swift_consistency.py
echo
for f in *_reference.py; do python3 "$f"; done
echo "Alle Referenzmodelle bestanden."
