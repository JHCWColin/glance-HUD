#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-HUDApp.xcodeproj}"
SCHEME="${SCHEME:-HUDApp}"
CONFIGURATION="${CONFIGURATION:-Release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

select_latest_stable_xcode() {
  mapfile -t candidates < <(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' ! -name '*beta*' | sort -V)

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "No stable Xcode installation was found under /Applications." >&2
    exit 1
  fi

  local last_index
  last_index=$((${#candidates[@]} - 1))
  export DEVELOPER_DIR="${candidates[$last_index]}/Contents/Developer"

  echo "Using Xcode from: $DEVELOPER_DIR"
  xcodebuild -version
}

build_simulator() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphonesimulator \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA/simulator" \
    CODE_SIGNING_ALLOWED=NO \
    clean build

  local app_path="$DERIVED_DATA/simulator/Build/Products/${CONFIGURATION}-iphonesimulator/HUDApp.app"

  if [ ! -d "$app_path" ]; then
    echo "Simulator app not found at $app_path" >&2
    exit 1
  fi

  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$DIST_DIR/HUDApp-simulator.zip"
}

build_device_unsigned() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA/device" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    clean build

  local app_path="$DERIVED_DATA/device/Build/Products/${CONFIGURATION}-iphoneos/HUDApp.app"
  local payload_dir="$BUILD_ROOT/Payload"

  if [ ! -d "$app_path" ]; then
    echo "Device app not found at $app_path" >&2
    exit 1
  fi

  rm -rf "$payload_dir"
  mkdir -p "$payload_dir"
  cp -R "$app_path" "$payload_dir/HUDApp.app"
  ditto -c -k --sequesterRsrc --keepParent "$payload_dir" "$DIST_DIR/HUDApp-device-unsigned.ipa"
}

main() {
  rm -rf "$BUILD_ROOT" "$DIST_DIR"
  mkdir -p "$BUILD_ROOT" "$DIST_DIR"

  select_latest_stable_xcode
  build_simulator
  build_device_unsigned

  echo "Artifacts created:"
  ls -lah "$DIST_DIR"
}

main "$@"
