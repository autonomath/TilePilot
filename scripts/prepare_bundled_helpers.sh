#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ARCH="$(uname -m)"
OUTPUT_DIR="$ROOT_DIR/dist/bundled-helpers/$ARCH/Helpers"
CACHE_DIR="$ROOT_DIR/dist/bundled-helpers-cache"

YABAI_VERSION="7.1.17"
YABAI_SOURCE_REVISION="v7.1.17"
YABAI_SOURCE_URL="https://github.com/asmvik/yabai/releases/download/v7.1.17/yabai-v7.1.17.tar.gz"
YABAI_SOURCE_SHA256="3a1d46a3c52811f092861c40ee31b1359976138b8b312b77340a002311786247"

SKHD_VERSION="0.3.9"
SKHD_SOURCE_REVISION="f88e7ad403ebbee1b8bac988d8b162d595f595c4"
SKHD_SOURCE_URL="https://codeload.github.com/asmvik/skhd/tar.gz/refs/tags/v0.3.9"
SKHD_SOURCE_SHA256="9ca31556288d4cdfbd57974a10a9486b9d2b7d44eba16be62878fd25dd8ab8d2"

usage() {
  cat <<EOF
Usage: scripts/prepare_bundled_helpers.sh [--output-dir <dir>]

Fetches and prepares the pinned yabai and skhd helper binaries for the current
machine architecture, then writes:
  yabai
  skhd
  helper-manifest.json

Default output:
  $OUTPUT_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      shift
      OUTPUT_DIR="${1:-}"
      if [[ -z "$OUTPUT_DIR" ]]; then
        echo "--output-dir requires a value" >&2
        exit 1
      fi
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

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

require_tool curl
require_tool tar
require_tool shasum
require_tool make
require_tool clang

mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tilepilot-helpers.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

download_if_needed() {
  local url="$1"
  local destination="$2"
  if [[ ! -f "$destination" ]]; then
    curl -L --fail --silent --show-error "$url" -o "$destination"
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA256 mismatch for $file" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

extract_yabai() {
  local archive="$CACHE_DIR/yabai-${YABAI_VERSION}.tar.gz"
  download_if_needed "$YABAI_SOURCE_URL" "$archive"
  verify_sha256 "$archive" "$YABAI_SOURCE_SHA256"

  local extract_dir="$WORK_DIR/yabai"
  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"

  local candidate="$extract_dir/archive/bin/yabai"
  [[ -f "$candidate" ]] || {
    echo "Bundled yabai binary not found in upstream archive." >&2
    exit 1
  }

  install -m 755 "$candidate" "$OUTPUT_DIR/yabai"
}

build_skhd() {
  local archive="$CACHE_DIR/skhd-${SKHD_VERSION}.tar.gz"
  download_if_needed "$SKHD_SOURCE_URL" "$archive"
  verify_sha256 "$archive" "$SKHD_SOURCE_SHA256"

  local extract_dir="$WORK_DIR/skhd"
  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"

  local source_dir
  source_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$source_dir" ]] || {
    echo "Failed to locate extracted skhd source directory." >&2
    exit 1
  }

  make -C "$source_dir" clean >/dev/null 2>&1 || true
  make -C "$source_dir" >/dev/null

  local candidate="$source_dir/bin/skhd"
  [[ -f "$candidate" ]] || {
    echo "Built skhd binary not found." >&2
    exit 1
  }

  install -m 755 "$candidate" "$OUTPUT_DIR/skhd"
}

binary_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_manifest() {
  local generated_at
  generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local yabai_checksum
  local skhd_checksum
  yabai_checksum="$(binary_sha256 "$OUTPUT_DIR/yabai")"
  skhd_checksum="$(binary_sha256 "$OUTPUT_DIR/skhd")"

  cat > "$OUTPUT_DIR/helper-manifest.json" <<EOF
{
  "generatedAt": "$generated_at",
  "helpers": [
    {
      "helper": "yabai",
      "version": "$YABAI_VERSION",
      "architecture": "$ARCH",
      "sourceURL": "$YABAI_SOURCE_URL",
      "sourceRevision": "$YABAI_SOURCE_REVISION",
      "checksumSHA256": "$yabai_checksum"
    },
    {
      "helper": "skhd",
      "version": "$SKHD_VERSION",
      "architecture": "$ARCH",
      "sourceURL": "$SKHD_SOURCE_URL",
      "sourceRevision": "$SKHD_SOURCE_REVISION",
      "checksumSHA256": "$skhd_checksum"
    }
  ]
}
EOF
}

extract_yabai
build_skhd
write_manifest

echo "$OUTPUT_DIR"
