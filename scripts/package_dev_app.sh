#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="TilePilot"
BUNDLE_ID="com.klode.tilepilot.dev"
SPM_PRODUCT="TilePilot"
ICON_SOURCE="assets/icon/tilepilot-icon-1024.png"
INSTALLER_BACKGROUND_SOURCE="assets/dmg/dmg-background.png"
CONFIGURATION="debug"
INSTALL_TO_APPLICATIONS=1
RUN_AFTER_BUILD=0
OPEN_AFTER_BUILD=1
KEEP_DIST_COPY=0
SIGN_APP=1
SIGN_IDENTITY="${TILEPILOT_CODESIGN_IDENTITY:-}"
APP_VERSION_INPUT="${TILEPILOT_APP_VERSION:-}"
BUILD_NUMBER_INPUT="${TILEPILOT_BUILD_NUMBER:-}"

usage() {
  cat <<EOF
Usage: scripts/package_dev_app.sh [options]

Packages the SwiftPM executable into a macOS app bundle and installs it to:
  /Applications/${APP_NAME}.app

Options:
  --release          Build in release mode (default: debug)
  --install          Copy the app bundle into /Applications (default)
  --no-install       Keep bundle only in dist/ (disables relaunch unless --open/--run is set)
  --keep-dist        Also keep a copy in dist/ after install (default: off)
  --no-sign         Skip code signing
  --sign-identity   Override signing identity (Developer ID Application...)
  --version         Bundle short version string (default: latest git tag or 0.0.0)
  --build-number    Bundle build number (default: git commit count or 1)
  --run              Run the packaged app after bundling
  --open             Launch the packaged app via LaunchServices after bundling (default)
  --no-open          Do not relaunch/open after bundling
  --help             Show this help

Examples:
  scripts/package_dev_app.sh
  scripts/package_dev_app.sh
  scripts/package_dev_app.sh --no-open
  scripts/package_dev_app.sh --no-install
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIGURATION="release"
      ;;
    --install)
      INSTALL_TO_APPLICATIONS=1
      ;;
    --no-install)
      INSTALL_TO_APPLICATIONS=0
      OPEN_AFTER_BUILD=0
      RUN_AFTER_BUILD=0
      ;;
    --keep-dist)
      KEEP_DIST_COPY=1
      ;;
    --no-sign)
      SIGN_APP=0
      ;;
    --sign-identity)
      shift
      SIGN_IDENTITY="${1:-}"
      if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "--sign-identity requires a value" >&2
        exit 1
      fi
      ;;
    --version)
      shift
      APP_VERSION_INPUT="${1:-}"
      if [[ -z "$APP_VERSION_INPUT" ]]; then
        echo "--version requires a value" >&2
        exit 1
      fi
      ;;
    --build-number)
      shift
      BUILD_NUMBER_INPUT="${1:-}"
      if [[ -z "$BUILD_NUMBER_INPUT" ]]; then
        echo "--build-number requires a value" >&2
        exit 1
      fi
      ;;
    --run)
      RUN_AFTER_BUILD=1
      ;;
    --open)
      OPEN_AFTER_BUILD=1
      ;;
    --no-open)
      OPEN_AFTER_BUILD=0
      RUN_AFTER_BUILD=0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

resolve_default_version() {
  if [[ -n "$APP_VERSION_INPUT" ]]; then
    echo "$APP_VERSION_INPUT"
    return 0
  fi
  local git_tag
  git_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$git_tag" ]]; then
    echo "$git_tag"
  else
    echo "0.0.0"
  fi
}

normalize_version() {
  local raw="$1"
  raw="${raw#v}"
  echo "$raw"
}

resolve_build_number() {
  if [[ -n "$BUILD_NUMBER_INPUT" ]]; then
    echo "$BUILD_NUMBER_INPUT"
    return 0
  fi
  local git_count
  git_count="$(git rev-list --count HEAD 2>/dev/null || true)"
  if [[ -n "$git_count" ]]; then
    echo "$git_count"
  else
    echo "1"
  fi
}

APP_VERSION_RAW="$(resolve_default_version)"
APP_VERSION="$(normalize_version "$APP_VERSION_RAW")"
BUILD_NUMBER="$(resolve_build_number)"
AUTOMATIC_UPDATE_CHECKS_ENABLED="false"
if [[ "$CONFIGURATION" == "release" ]]; then
  AUTOMATIC_UPDATE_CHECKS_ENABLED="true"
fi

echo "Building Swift package (${CONFIGURATION})..."
if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release
else
  swift build
fi

BIN_PATH=".build/${CONFIGURATION}/${SPM_PRODUCT}"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Expected binary not found: $BIN_PATH" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
DEST="/Applications/${APP_NAME}.app"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tilepilot-build.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
APP_DIR="$STAGE_ROOT/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE_PATH="$MACOS_DIR/${APP_NAME}"
HELPERS_STAGE_DIR=""

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

prepare_bundled_helpers() {
  echo "Preparing bundled helpers..."
  HELPERS_STAGE_DIR="$("$ROOT_DIR/scripts/prepare_bundled_helpers.sh")"
}

copy_bundled_helpers() {
  [[ -n "$HELPERS_STAGE_DIR" ]] || return 1
  local destination="$RESOURCES_DIR/Helpers"
  rm -rf "$destination"
  mkdir -p "$destination"
  cp "$HELPERS_STAGE_DIR/yabai" "$destination/yabai"
  cp "$HELPERS_STAGE_DIR/skhd" "$destination/skhd"
  cp "$HELPERS_STAGE_DIR/helper-manifest.json" "$destination/helper-manifest.json"
  chmod 755 "$destination/yabai" "$destination/skhd"
  xattr -cr "$destination" 2>/dev/null || true
}

maybe_build_icon() {
  local icon_src="$ROOT_DIR/$ICON_SOURCE"
  [[ -f "$icon_src" ]] || return 0

  if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
    echo "Skipping icon build (sips/iconutil not available)."
    return 0
  fi

  local iconset_dir="$STAGE_ROOT/AppIcon.iconset"
  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  make_icon() {
    local size="$1"
    local out="$2"
    sips -z "$size" "$size" "$icon_src" --out "$iconset_dir/$out" >/dev/null
  }

  make_icon 16 icon_16x16.png
  make_icon 32 icon_16x16@2x.png
  make_icon 32 icon_32x32.png
  make_icon 64 icon_32x32@2x.png
  make_icon 128 icon_128x128.png
  make_icon 256 icon_128x128@2x.png
  make_icon 256 icon_256x256.png
  make_icon 512 icon_256x256@2x.png
  make_icon 512 icon_512x512.png
  cp "$icon_src" "$iconset_dir/icon_512x512@2x.png"

  iconutil -c icns "$iconset_dir" -o "$RESOURCES_DIR/AppIcon.icns"
}

copy_installer_background() {
  local background_src="$ROOT_DIR/$INSTALLER_BACKGROUND_SOURCE"
  [[ -f "$background_src" ]] || return 0
  cp "$background_src" "$RESOURCES_DIR/InstallerBackground.png"
}

resolve_sign_identity() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "$SIGN_IDENTITY"
    return 0
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application: / {print $2}' \
    | head -n 1
}

sign_app_bundle() {
  local app_path="$1"
  local helpers_dir="$app_path/Contents/Resources/Helpers"
  if [[ $SIGN_APP -eq 0 ]]; then
    if [[ -d "$helpers_dir" ]]; then
      for helper in yabai skhd; do
        if [[ -f "$helpers_dir/$helper" ]]; then
          /usr/bin/codesign --force --sign - "$helpers_dir/$helper"
        fi
      done
    fi
    echo "Applying ad-hoc signature (no identity requested)."
    /usr/bin/codesign --force --deep --sign - "$app_path"
    /usr/bin/codesign --verify --deep --strict "$app_path"
    return 0
  fi
  local identity
  identity="$(resolve_sign_identity)"
  if [[ -z "$identity" ]]; then
    if [[ -d "$helpers_dir" ]]; then
      for helper in yabai skhd; do
        if [[ -f "$helpers_dir/$helper" ]]; then
          /usr/bin/codesign --force --sign - "$helpers_dir/$helper"
        fi
      done
    fi
    echo "No Developer ID Application identity found; applying ad-hoc signature."
    /usr/bin/codesign --force --deep --sign - "$app_path"
    /usr/bin/codesign --verify --deep --strict "$app_path"
    return 0
  fi
  if [[ -d "$helpers_dir" ]]; then
    for helper in yabai skhd; do
      if [[ -f "$helpers_dir/$helper" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$helpers_dir/$helper"
      fi
    done
  fi
  echo "Signing app with: $identity"
  /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_path"
  /usr/bin/codesign --verify --deep --strict "$app_path"
}

prepare_bundled_helpers
copy_bundled_helpers
maybe_build_icon
copy_installer_background

cat > "$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}.deeplink</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>tilepilot</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>TilePilotEnableAutomaticUpdateChecks</key>
  <${AUTOMATIC_UPDATE_CHECKS_ENABLED}/>
</dict>
</plist>
EOF

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$INFO_PLIST" >/dev/null
fi

if [[ $INSTALL_TO_APPLICATIONS -eq 1 ]]; then
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Stopping running ${APP_NAME} before install..."
    pkill -x "$APP_NAME" || true
    sleep 0.4
  fi
  echo "Installing to $DEST ..."
  rm -rf "$DEST"
  cp -R "$APP_DIR" "$DEST"
  sign_app_bundle "$DEST"
  echo "Installed:"
  echo "  $DEST"
  if [[ $KEEP_DIST_COPY -eq 1 ]]; then
    mkdir -p "$DIST_DIR"
    rm -rf "$DIST_DIR/${APP_NAME}.app"
    cp -R "$DEST" "$DIST_DIR/${APP_NAME}.app"
    echo "Kept dist copy:"
    echo "  $DIST_DIR/${APP_NAME}.app"
  else
    rm -rf "$DIST_DIR/${APP_NAME}.app" 2>/dev/null || true
  fi
else
  mkdir -p "$DIST_DIR"
  rm -rf "$DIST_DIR/${APP_NAME}.app"
  cp -R "$APP_DIR" "$DIST_DIR/${APP_NAME}.app"
  sign_app_bundle "$DIST_DIR/${APP_NAME}.app"
  echo "Packaged app:"
  echo "  $DIST_DIR/${APP_NAME}.app"
fi

if [[ $OPEN_AFTER_BUILD -eq 1 ]]; then
  TARGET="$DIST_DIR/${APP_NAME}.app"
  if [[ $INSTALL_TO_APPLICATIONS -eq 1 ]]; then
    TARGET="$DEST"
  fi
  open "$TARGET"
fi

if [[ $RUN_AFTER_BUILD -eq 1 ]]; then
  TARGET="$EXECUTABLE_PATH"
  if [[ $INSTALL_TO_APPLICATIONS -eq 1 ]]; then
    TARGET="$DEST/Contents/MacOS/${APP_NAME}"
  fi
  "$TARGET" &
  disown || true
fi
