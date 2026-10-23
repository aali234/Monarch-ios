#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
: "${MONARCH_SIMULATOR_UDID:?Set MONARCH_SIMULATOR_UDID to an iOS 26+ iPhone simulator UUID (xcrun simctl list devices available).}"
signing_flags=(CODE_SIGNING_ALLOWED=NO)
if [[ "${MONARCH_SIMULATOR_SIGNING:-unsigned}" == adhoc ]]; then
  signing_flags=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi
xcodebuild -project Monarch.xcodeproj -scheme Monarch -configuration Debug -destination "id=$MONARCH_SIMULATOR_UDID" -derivedDataPath build/DerivedData -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" "${signing_flags[@]}" test
