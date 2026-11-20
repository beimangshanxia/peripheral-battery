#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in
  run|--build-only|--debug|--logs|--telemetry|--verify) ;;
  *)
    echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
app_name="PeripheralBattery"
bundle_id="local.beimang.PeripheralBattery"
app_bundle="$PWD/dist/$app_name.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"
stamp=".build/$app_name.bundle-checksums"

bash ./script/swiftpm.sh build
build_binary="$(bash ./script/swiftpm.sh build --show-bin-path)/$app_name"
checksums="$(/usr/bin/shasum -a 256 "$build_binary" script/Info.plist)"
mkdir -p "$app_bundle/Contents/MacOS"
if [[ ! -f "$stamp" || "$(<"$stamp")" != "$checksums" ]] ||
   ! /usr/bin/codesign --verify "$app_bundle" 2>/dev/null; then
  cp script/Info.plist "$app_bundle/Contents/Info.plist"
  install -m 755 "$build_binary" "$app_binary"
  /usr/bin/codesign --force --sign - "$app_bundle"
  printf '%s\n' "$checksums" > "$stamp"
fi

if [[ "$mode" == --build-only ]]; then
  printf '%s\n' "$app_bundle"
  exit
fi

/usr/bin/pkill -f "^$app_binary$" >/dev/null 2>&1 || true
/usr/bin/open -n "$app_bundle"

case "$mode" in
  --debug) lldb -n "$app_name" -w ;;
  --logs) /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\"" ;;
  --telemetry) /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\"" ;;
  --verify)
    for attempt in 1 2 3 4 5; do
      if /usr/bin/pgrep -f "^$app_binary$" >/dev/null; then
        printf 'Running %s\n' "$app_bundle"
        exit 0
      fi
      sleep 1
    done
    echo "The app did not stay running." >&2
    exit 1
    ;;
esac
