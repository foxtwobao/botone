#!/usr/bin/env bash
# Runs the existing catalog with its isolated offline fixtures on a real iPad simulator.
set -euo pipefail

out="$PWD/test-report/ios-screenshots"
mkdir -p "$out"
export IOS_SCREENSHOT_OUT="$out"

maestro_tmp=$(mktemp -d "$RUNNER_TEMP/botone-maestro.XXXXXX")
curl --fail --silent --show-error --location \
  https://github.com/mobile-dev-inc/maestro/releases/download/cli-2.6.1/maestro.zip \
  --output "$maestro_tmp/maestro.zip"
echo '3440825f514f537c6a96bcf5de995780c2a4a7f83a43208fdc95d4f1fecfad3b  maestro.zip' |
  (cd "$maestro_tmp" && shasum -a 256 --check -)
unzip -q "$maestro_tmp/maestro.zip" -d "$maestro_tmp"
export PATH="$maestro_tmp/maestro/bin:$PATH"
maestro --version

if ! brew list --versions postgresql@18 >/dev/null 2>&1; then
  brew install postgresql@18
fi
pg_bin="$(brew --prefix postgresql@18)/bin"
pg_data=$(mktemp -d "$RUNNER_TEMP/botone-screenshot-postgres.XXXXXX")
"$pg_bin/initdb" -D "$pg_data" -U screenshot --auth=trust > "$out/postgres-init.log" 2>&1
"$pg_bin/pg_ctl" -D "$pg_data" -l "$out/postgres.log" \
  -o "-h 127.0.0.1 -p 5439 -k $RUNNER_TEMP" -w start

sim_udid=''
cleanup() {
  if [[ -n "$sim_udid" ]]; then
    xcrun simctl shutdown "$sim_udid" || true
    xcrun simctl delete "$sim_udid" || true
  fi
  "$pg_bin/pg_ctl" -D "$pg_data" -m immediate -w stop || true
}
trap cleanup EXIT

xcrun simctl list --json > "$out/simulators.json"
read -r device_type runtime < <(python3 - "$out/simulators.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1]))
runtimes = [r for r in data['runtimes'] if r.get('isAvailable') and r.get('platform') == 'iOS']
if not runtimes:
    raise SystemExit('A 13-inch iPad device type and an iOS simulator runtime are required')
for runtime in sorted(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))), reverse=True):
    devices = [
        d for d in runtime.get('supportedDeviceTypes', [])
        if d.get('productFamily') == 'iPad' and 'iPad Pro 13-inch' in d['name']
    ]
    if devices:
        print(devices[0]['identifier'], runtime['identifier'])
        break
else:
    raise SystemExit('No installed iOS runtime supports a 13-inch iPad simulator')
PY
)
sim_udid=$(xcrun simctl create "BotONE screenshot iPad" "$device_type" "$runtime")
export SIM_UDID="$sim_udid"
xcrun simctl boot "$sim_udid"
xcrun simctl bootstatus "$sim_udid" -b
xcrun simctl ui "$sim_udid" appearance light
xcrun simctl status_bar "$sim_udid" override --time '9:41' \
  --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100

# Remove cloud project metadata only in this disposable checkout; keep the catalog's app ID.
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const file = 'apps/mobile/app.json';
const config = JSON.parse(readFileSync(file, 'utf8'));
delete config.expo.owner;
delete config.expo.extra.eas;
config.expo.updates = { enabled: false };
writeFileSync(file, JSON.stringify(config, null, 2) + '\n');
JS

pnpm --filter @rakazo/mobile exec expo prebuild --platform ios
xcodebuild -workspace apps/mobile/ios/BotONE.xcworkspace -scheme BotONE \
  -configuration Debug -sdk iphonesimulator -destination "id=$sim_udid" \
  -derivedDataPath "$RUNNER_TEMP/botone-ipad" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_IDENTITY=- build > "$out/xcodebuild.log" 2>&1 || {
    tail -n 100 "$out/xcodebuild.log"
    exit 1
  }
xcrun simctl install "$sim_udid" \
  "$RUNNER_TEMP/botone-ipad/Build/Products/Debug-iphonesimulator/BotONE.app"

# The bundled release points to the same local API that the existing catalog starts.
# These sections provide the primary product screens without production accounts or models.
pnpm ios:screenshots -- --section inbox --section thread --section compose --section skills
