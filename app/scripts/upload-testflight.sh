#!/bin/bash
# Baut iOS und macOS als Release, erhöht die Buildnummer und lädt beide
# nach TestFlight hoch. Nutzt den in Xcode angemeldeten Account.
set -euo pipefail
cd "$(dirname "$0")/.."

# Ohne Zugang zum Podcast-Katalog baut die App trotzdem, zeigt aber weder
# Angesagt noch Kategorien. Das soll beim Hochladen niemand übersehen.
CREDS=Config/PodcastIndex/PodcastIndexCredentials.plist
if ! /usr/libexec/PlistBuddy -c "Print :APIKey" "$CREDS" 2>/dev/null | grep -q . \
   || ! /usr/libexec/PlistBuddy -c "Print :APISecret" "$CREDS" 2>/dev/null | grep -q .; then
  echo "Achtung: $CREDS fehlt oder ist unvollständig. Dieser Build kommt ohne Podcast-Katalog." >&2
fi

BUILD=$(date +%Y%m%d%H%M)
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate >/dev/null

OUT=build/testflight
rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>SP73Z8JWXM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
PLIST

for pair in "PodcastAI:generic/platform=iOS" "PodcastAIMac:generic/platform=macOS"; do
  scheme=${pair%%:*}; dest=${pair#*:}
  echo "== $scheme: Archiv (Build $BUILD)"
  xcodebuild -project PodcastAI.xcodeproj -scheme "$scheme" -configuration Release \
    -destination "$dest" -archivePath "$OUT/$scheme.xcarchive" -allowProvisioningUpdates \
    archive -quiet
  echo "== $scheme: Upload"
  xcodebuild -exportArchive -archivePath "$OUT/$scheme.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/$scheme" \
    -allowProvisioningUpdates
done
echo "Fertig. Build $BUILD ist in App Store Connect unterwegs."
