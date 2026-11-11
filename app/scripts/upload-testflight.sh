#!/bin/bash
# Baut iOS, macOS und tvOS als Release, erhöht die Buildnummer und lädt die
# Builds nach TestFlight hoch. Nutzt den in Xcode angemeldeten Account.
# INTERNAL_ONLY=true lädt Builds nur für interne Tester hoch; solche Builds
# lassen sich nicht im App Store einreichen.
# Vor jedem Upload exportiert das Skript die App einmal lokal, und
# scripts/verify-signing.py prüft die Berechtigungen der für den Vertrieb
# signierten App (Private Cloud Compute, iCloud, Push, Sandbox, App Group).
set -euo pipefail
cd "$(dirname "$0")/.."

INTERNAL_ONLY=${INTERNAL_ONLY:-false}
case $INTERNAL_ONLY in
  true|false) ;;
  *) echo "INTERNAL_ONLY muss true oder false sein, nicht \"$INTERNAL_ONLY\"." >&2; exit 1 ;;
esac

set_build() {
  sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$1\"/" project.yml
  xcodegen generate >/dev/null
}
PREVIOUS=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)".*/\1/p' project.yml | head -1)
[ -n "$PREVIOUS" ] || { echo "CURRENT_PROJECT_VERSION fehlt in project.yml." >&2; exit 1; }
BUILD=$(date +%Y%m%d%H%M)
# Scheitert der Lauf, bevor etwas hochgeladen ist, gilt wieder die alte
# Buildnummer. Sonst stünde im Projekt eine Nummer, die Apple nie gesehen hat.
uploaded=
trap '[ -n "$uploaded" ] || { set_build "$PREVIOUS"; echo "Nichts hochgeladen, Buildnummer wieder $PREVIOUS." >&2; }' EXIT
set_build "$BUILD"

OUT=build/testflight
rm -rf "$OUT"; mkdir -p "$OUT"
# Zweimal dieselben Angaben: erst lokal exportieren und prüfen, dann hochladen.
for destination in export upload; do
  cat > "$OUT/ExportOptions-$destination.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>SP73Z8JWXM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><$INTERNAL_ONLY/>
</dict></plist>
PLIST
done

# PLATFORMS wählt die Ziele, etwa PLATFORMS="PodcastAITV:generic/platform=tvOS".
# Die iPhone-App bringt die Uhr mit. Apple TV hat in diesem Team kein
# registriertes Gerät, deshalb wird dort unsigniert archiviert und beim
# Export mit dem Verteilungszertifikat signiert.
PLATFORMS=${PLATFORMS:-"PodcastAI:generic/platform=iOS PodcastAIMac:generic/platform=macOS PodcastAITV:generic/platform=tvOS"}
for pair in $PLATFORMS; do
  scheme=${pair%%:*}; dest=${pair#*:}
  archive="$OUT/$scheme.xcarchive"
  echo "== $scheme: Archiv (Build $BUILD)"
  extra=()
  [ "$scheme" = PodcastAITV ] && extra=(CODE_SIGNING_ALLOWED=NO)
  xcodebuild -project PodcastAI.xcodeproj -scheme "$scheme" -configuration Release \
    -destination "$dest" -archivePath "$archive" -allowProvisioningUpdates \
    ${extra[@]+"${extra[@]}"} archive -quiet
  if [ "$scheme" = PodcastAITV ]; then
    # Der Export übernimmt nur Berechtigungen, die in der Signatur des Archivs
    # stehen, und ein unsigniertes Archiv hat keine. Ohne diesen Schritt fehlt
    # der fertigen App iCloud, und die Bibliothek auf dem Fernseher bleibt leer.
    codesign --force --sign - --generate-entitlement-der \
      --entitlements Apps/PodcastAITV/PodcastAITV.entitlements \
      "$archive/Products/Applications/PodcastAI.app"
  fi
  # Fehlt der App eine Berechtigung (Private Cloud Compute, iCloud), läuft sie
  # an, meldet aber auf dem Gerät „nicht verfügbar“. Geprüft wird die für den
  # Vertrieb signierte App, also das, was Apple bekommt.
  echo "== $scheme: Signatur prüfen"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$OUT/ExportOptions-export.plist" -exportPath "$OUT/$scheme-check" \
    -allowProvisioningUpdates
  python3 scripts/verify-signing.py --distribution "$OUT/$scheme-check"/PodcastAI.*
  echo "== $scheme: Upload"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$OUT/ExportOptions-upload.plist" -exportPath "$OUT/$scheme" \
    -allowProvisioningUpdates
  uploaded=1
done
echo "Fertig. Build $BUILD ist in App Store Connect unterwegs."
