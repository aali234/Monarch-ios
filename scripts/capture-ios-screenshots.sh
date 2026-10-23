#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo 'This script runs on a Mac or GitHub macOS runner with Xcode 26+.' >&2
  exit 1
fi
mkdir -p build
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, version, "."); print version[1]}')"
if [[ "${xcode_major:-0}" -lt 26 ]]; then
  echo 'Select Xcode 26+ before running the screenshot job.' >&2
  exit 1
fi
device_id="${MONARCH_SIMULATOR_UDID:-}"
if [[ -z "$device_id" ]]; then
  device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
choices = []
for runtime, rows in json.load(sys.stdin)["devices"].items():
    match = re.search(r"iOS-(\d+(?:-\d+)*)$", runtime)
    if not match:
        continue
    version = tuple(map(int, match.group(1).split("-")))
    if version[0] < 26:
        continue
    for row in rows:
        if row.get("isAvailable") and row["name"].startswith("iPhone"):
            choices.append((version, row["name"] == "iPhone 17 Pro", row["name"] == "iPhone 16 Pro", row["udid"]))
if choices:
    print(max(choices)[-1])
')"
fi
if [[ -z "$device_id" ]]; then
  echo 'No available iOS 26+ iPhone simulator was found on this runner.' >&2
  exit 1
fi
if [[ -e build/Screenshots.xcresult || -e build/Screenshots ]]; then
  echo 'Move previous build/Screenshots and build/Screenshots.xcresult outputs before starting another capture.' >&2
  exit 1
fi
if ! xcrun simctl list devices booted --json | python3 -c 'import json,sys; target=sys.argv[1]; sys.exit(0 if any(row["udid"] == target for rows in json.load(sys.stdin)["devices"].values() for row in rows) else 1)' "$device_id"; then
  xcrun simctl boot "$device_id"
fi
xcrun simctl bootstatus "$device_id" -b
xcrun simctl ui "$device_id" appearance light
xcrun simctl status_bar "$device_id" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
trap 'xcrun simctl status_bar "$device_id" clear >/dev/null 2>&1 || true' EXIT
{
  xcodebuild -version
  xcrun simctl list devices booted
  echo 'Screenshot data: synthetic examples in an in-memory ledger; no live bank, mail, or carrier session.'
} > build/simulator-environment.txt

signing_flags=(CODE_SIGNING_ALLOWED=NO)
if [[ "${MONARCH_SIMULATOR_SIGNING:-unsigned}" == adhoc ]]; then
  signing_flags=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi
set +e
xcodebuild -project Monarch.xcodeproj -scheme Monarch -configuration Debug \
  -destination "id=$device_id" -destination-timeout 180 \
  -derivedDataPath build/DerivedData -resultBundlePath build/Screenshots.xcresult \
  -parallel-testing-enabled NO -only-testing:MonarchUITests/ScreenshotTests \
  "${signing_flags[@]}" test 2>&1 | tee build/ios-screenshots.log
test_status=${PIPESTATUS[0]}
set -e
if [[ -d build/Screenshots.xcresult ]]; then
  # keepAlways XCTAttachments include the real simulator PNGs and a filename manifest.
  xcrun xcresulttool export attachments --path build/Screenshots.xcresult --output-path build/Screenshots || exit 1
fi
if [[ "$test_status" -ne 0 ]]; then
  echo 'The native build/UI run failed. Inspect ios-screenshots.log and the result bundle.' >&2
  exit "$test_status"
fi
python3 - <<'PY'
from pathlib import Path
screenshots = [path for path in Path('build/Screenshots').rglob('*') if path.is_file() and path.suffix.lower() == '.png']
if len(screenshots) < 10:
    raise SystemExit(f'Expected ten screen captures, found {len(screenshots)} PNGs. Inspect the result bundle.')
print(f'Exported {len(screenshots)} PNG screenshots.')
PY
echo 'Screenshots are in build/Screenshots; open manifest.json for their named test activities.'
