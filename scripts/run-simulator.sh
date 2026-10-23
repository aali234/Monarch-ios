#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo 'Run this script on a Mac with Xcode 26+ and an iOS 26+ Simulator runtime installed.' >&2
  exit 1
fi
device_id="${MONARCH_SIMULATOR_UDID:-}"
if [[ -z "$device_id" ]]; then
  device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
choices = []
for runtime, rows in devices.items():
    match = re.search(r"iOS-(\d+)", runtime)
    if not match or int(match.group(1)) < 26:
        continue
    for row in rows:
        if row.get("isAvailable") and "iPhone" in row["name"]:
            choices.append((row["state"] == "Booted", "iPhone 16" == row["name"], row["udid"]))
if choices:
    print(sorted(choices, reverse=True)[0][2])
')"
fi
if [[ -z "$device_id" ]]; then
  echo 'Install an iOS 26+ iPhone Simulator in Xcode → Settings → Components, then retry.' >&2
  exit 1
fi
open -a Simulator
if ! xcrun simctl list devices booted --json | python3 -c 'import json,sys; target=sys.argv[1]; sys.exit(0 if any(d["udid"] == target for rows in json.load(sys.stdin)["devices"].values() for d in rows) else 1)' "$device_id"; then
  xcrun simctl boot "$device_id"
fi
xcrun simctl bootstatus "$device_id" -b
signing_flags=(CODE_SIGNING_ALLOWED=NO)
if [[ "${MONARCH_SIMULATOR_SIGNING:-unsigned}" == adhoc ]]; then
  signing_flags=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi
xcodebuild -resolvePackageDependencies -project Monarch.xcodeproj -scheme Monarch
xcodebuild -project Monarch.xcodeproj -scheme Monarch -configuration Debug -destination "id=$device_id" -derivedDataPath build/DerivedData "${signing_flags[@]}" build
xcrun simctl install "$device_id" build/DerivedData/Build/Products/Debug-iphonesimulator/Monarch.app
xcrun simctl launch "$device_id" com.aali.monarch.sandbox
echo 'Open More → Settings, enter the proxy app key from proxy/.env, then add a Sandbox bank.'
