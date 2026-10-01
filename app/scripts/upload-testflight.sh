#!/bin/bash
# Baut iOS und macOS als Release, erhöht die Buildnummer und lädt beide
# nach TestFlight hoch. Nutzt den in Xcode angemeldeten Account.
# INTERNAL_ONLY=true lädt Builds nur für interne Tester hoch; solche Builds
# lassen sich nicht im App Store einreichen.
set -euo pipefail
cd "$(dirname "$0")/.."

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
  <key>testFlightInternalTestingOnly</key><${INTERNAL_ONLY:-false}/>
</dict></plist>
PLIST

# PLATFORMS wählt die Ziele, etwa PLATFORMS="PodcastAITV:generic/platform=tvOS".
# Die iPhone-App bringt die Uhr mit. Apple TV hat in diesem Team kein
# registriertes Gerät, deshalb wird dort unsigniert archiviert und beim
# Export mit dem Verteilungszertifikat signiert.
PLATFORMS=${PLATFORMS:-"PodcastAI:generic/platform=iOS PodcastAIMac:generic/platform=macOS PodcastAITV:generic/platform=tvOS"}
for pair in $PLATFORMS; do
  scheme=${pair%%:*}; dest=${pair#*:}
  echo "== $scheme: Archiv (Build $BUILD)"
  extra=()
  [ "$scheme" = PodcastAITV ] && extra=(CODE_SIGNING_ALLOWED=NO)
  xcodebuild -project PodcastAI.xcodeproj -scheme "$scheme" -configuration Release \
    -destination "$dest" -archivePath "$OUT/$scheme.xcarchive" -allowProvisioningUpdates \
    ${extra[@]+"${extra[@]}"} archive -quiet
  echo "== $scheme: Upload"
  xcodebuild -exportArchive -archivePath "$OUT/$scheme.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/$scheme" \
    -allowProvisioningUpdates
done
echo "Fertig. Build $BUILD ist in App Store Connect unterwegs."
