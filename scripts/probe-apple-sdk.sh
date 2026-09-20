#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo "NOT RUN: Apple SDK probes require macOS and Xcode 27." >&2; exit 2; fi
OUT="$ROOT/validation/apple-sdk/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
xcodebuild -version > "$OUT/xcode.txt"
xcrun swift --version > "$OUT/swift.txt"
xcodebuild -showsdks > "$OUT/sdks.txt"
if ! grep -Eq 'Xcode 27([. ]|$)' "$OUT/xcode.txt"; then echo "Unsupported selected Xcode; see $OUT" >&2; exit 2; fi
printf 'sdk,probe,result\n' > "$OUT/results.csv"
failed=0
for pair in 'iphoneos:arm64-apple-ios27.0' 'watchos:arm64_32-apple-watchos27.0' 'macosx:arm64-apple-macosx27.0'; do
 sdk="${pair%%:*}"; target="${pair#*:}"
 sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
 xcrun --sdk "$sdk" --show-sdk-version > "$OUT/$sdk-version.txt"
 probe_names='Common PCC'
 if [[ "$sdk" != watchos ]]; then probe_names="$probe_names FullClient Sync Translation"; fi
 if [[ "$sdk" == iphoneos ]]; then probe_names="$probe_names Background WatchConnectivity"; fi
 if [[ "$sdk" == watchos ]]; then probe_names="$probe_names WatchConnectivity"; fi
 for name in $probe_names; do
  if xcrun --sdk "$sdk" swiftc -swift-version 6 -typecheck -sdk "$sdkpath" -target "$target" "$ROOT/scripts/apple-probes/$name.swift" > "$OUT/$sdk-$name.log" 2>&1; then
    printf '%s,%s,passed\n' "$sdk" "$name" >> "$OUT/results.csv"
  else
    printf '%s,%s,failed\n' "$sdk" "$name" >> "$OUT/results.csv"; failed=1
  fi
 done
done
printf '%s\n' 'iPadOS shares iphoneos SDK; iPad runtime/layout must still be tested separately.' > "$OUT/limitations.txt"
printf '%s\n' 'Typecheck does not validate entitlement, signing, device capability, runtime, performance or complete app compilation.' >> "$OUT/limitations.txt"
echo "Probe outputs: $OUT"
exit "$failed"
