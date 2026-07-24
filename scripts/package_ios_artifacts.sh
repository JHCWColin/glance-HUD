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
  local candidate
  local best_app=""
  local best_version=""

  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue

    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$candidate/Contents/Info.plist" 2>/dev/null || echo "0")

    if [ -z "$best_version" ] || version_gt "$version" "$best_version"; then
      best_app="$candidate"
      best_version="$version"
    fi
  done <<EOF
$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' ! -name '*beta*' | sort)
EOF

  if [ -z "$best_app" ]; then
    echo "No stable Xcode installation was found under /Applications." >&2
    exit 1
  fi

  export DEVELOPER_DIR="$best_app/Contents/Developer"

  echo "Using Xcode from: $DEVELOPER_DIR"
  xcodebuild -version
}

version_gt() {
  [ "$1" = "$2" ] && return 1

  local IFS=.
  local left_parts=($1)
  local right_parts=($2)
  local count=${#left_parts[@]}
  local index

  if [ "${#right_parts[@]}" -gt "$count" ]; then
    count=${#right_parts[@]}
  fi

  for ((index = 0; index < count; index++)); do
    local left="${left_parts[$index]:-0}"
    local right="${right_parts[$index]:-0}"

    if ((10#$left > 10#$right)); then
      return 0
    fi

    if ((10#$left < 10#$right)); then
      return 1
    fi
  done

  return 1
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

  local app_path="$DERIVED_DATA/simulator/Build/Products/${CONFIGURATION}-iphonesimulator/${SCHEME}.app"

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

  local app_path="$DERIVED_DATA/device/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
  local payload_dir="$BUILD_ROOT/Payload"

  if [ ! -d "$app_path" ]; then
    echo "Device app not found at $app_path" >&2
    exit 1
  fi

  rm -rf "$payload_dir"
  mkdir -p "$payload_dir"
  cp -R "$app_path" "$payload_dir/${SCHEME}.app"
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
