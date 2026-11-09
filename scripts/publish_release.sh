#!/usr/bin/env bash
# Publish a TilePilot release from the Autonomath staging checkout (public main).
#
#   scripts/publish_release.sh [--dry-run] vX.Y.Z NOTES.md
#
# Releases every local commit newer than the one behind the latest public tag, skipping any
# whose subject was already pushed since. --dry-run stops after applying them and resets staging.
set -euo pipefail

usage() { echo "usage: scripts/publish_release.sh [--dry-run] vX.Y.Z NOTES.md" >&2; exit 1; }
fail() { echo "error: $*" >&2; exit 1; }

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; shift; fi
VERSION=${1:-}; NOTES=${2:-}
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ -f "$NOTES" ]] || fail "notes file not found: $NOTES"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

LOCAL="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="${TILEPILOT_STAGING:-$HOME/Documents/ChatGPT/DevPloy/migration/staging/TilePilot}"
NUMBER="${VERSION#v}"
DMG="dist/TilePilot-$VERSION.dmg"
APP_PATHS=(Sources Tests Package.swift AGENTS.md scripts/package_dev_app.sh scripts/build_release_dmg.sh scripts/prepare_bundled_helpers.sh)
gh_autonomath() { GH_CONFIG_DIR="$HOME/.config/gh-autonomath" gh "$@"; }

cd "$STAGING"
git fetch -q origin --tags
[[ -z "$(git status --porcelain)" ]] || fail "staging checkout has uncommitted changes"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "staging main differs from origin/main"
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && fail "$VERSION already exists"
PREVIOUS="$(git describe --tags --abbrev=0 origin/main)"

# Local history is not public history, so commits are matched by subject.
base_subject="$(git log -1 --format=%s "$PREVIOUS^{commit}")"
pushed_since="$(git log --format=%s "$PREVIOUS..origin/main")"
commits=()
for c in $(git -C "$LOCAL" rev-list --reverse HEAD); do
    subject="$(git -C "$LOCAL" log -1 --format=%s "$c")"
    if [[ "$subject" == "$base_subject" ]]; then commits=(); continue; fi
    grep -qxF -- "$subject" <<<"$pushed_since" || commits+=("$c")
done
(( ${#commits[@]} )) || fail "no local commits since $PREVIOUS"
echo "Releasing $VERSION (after $PREVIOUS) with:"
for c in "${commits[@]}"; do git -C "$LOCAL" log -1 --format='  %h %s' "$c"; done

# Nothing is public until the push, so undo staging commits on any earlier failure.
trap 'git -C "$STAGING" reset -q --hard origin/main' EXIT
for c in "${commits[@]}"; do
    git -C "$LOCAL" format-patch -1 --stdout "$c" | git apply --index
    git commit -q -m "$(git -C "$LOCAL" log -1 --format=%B "$c")"
done
git -C "$LOCAL" fetch -q "$STAGING" +HEAD:refs/tmp/staging-head
git -C "$LOCAL" diff --quiet refs/tmp/staging-head HEAD -- "${APP_PATHS[@]}" \
    || { git -C "$LOCAL" diff --stat refs/tmp/staging-head HEAD -- "${APP_PATHS[@]}"; fail "staging app code differs from local HEAD"; }
echo "Staging app code matches local HEAD."
if (( DRY_RUN )); then echo "Dry run: staging reset to origin/main."; exit 0; fi

LOG="/tmp/tilepilot-$VERSION-build.log"
echo "Building and notarizing (log: $LOG)..."
TILEPILOT_NOTARY_PROFILE=TilePilot scripts/build_release_dmg.sh --version "$VERSION" --notarize --notary-profile TilePilot >"$LOG" 2>&1
grep -q 'status: Accepted' "$LOG" || fail "notarization was not accepted"
xcrun stapler validate "$DMG" >/dev/null
MOUNT="$(mktemp -d /tmp/tp-mnt.XXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
spctl --assess --type execute "$MOUNT/TilePilot.app"
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$MOUNT/TilePilot.app/Contents/Info.plist")"
hdiutil detach "$MOUNT" >/dev/null
[[ "$built" == "$NUMBER" ]] || fail "DMG app version is $built"

git tag -s "$VERSION" -m "TilePilot $NUMBER"
git push -q origin main "$VERSION"
trap - EXIT
(cd dist && shasum -a 256 "TilePilot-$VERSION.dmg" >SHA256SUMS.txt)
gh_autonomath release create "$VERSION" -R autonomath/TilePilot --verify-tag --latest \
    --title "TilePilot $NUMBER" --notes-file "$NOTES" "$DMG" dist/SHA256SUMS.txt

download="$(mktemp /tmp/tp-dl.XXXX)"
curl -fsSL -o "$download" "https://github.com/autonomath/TilePilot/releases/download/$VERSION/TilePilot-$VERSION.dmg"
[[ "$(shasum -a 256 "$download" | cut -d' ' -f1)" == "$(cut -d' ' -f1 dist/SHA256SUMS.txt)" ]] || fail "public download checksum differs"
latest="$(gh_autonomath api repos/autonomath/TilePilot/releases/latest --jq .tag_name)"
[[ "$latest" == "$VERSION" ]] || fail "latest release is $latest"

sed -i '' "s/${PREVIOUS#v}/$NUMBER/g" website/index.html
git commit -q -am "docs: point the website at $VERSION"
git push -q origin main

osascript -e 'quit app "TilePilot"' || true
for _ in $(seq 1 50); do pgrep -f /Applications/TilePilot.app/Contents/MacOS/TilePilot >/dev/null || break; sleep 0.2; done
backup="$(mktemp -d "/tmp/TilePilot-before-$VERSION.XXXX")"
mv /Applications/TilePilot.app "$backup/"
MOUNT="$(mktemp -d /tmp/tp-mnt.XXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
ditto "$MOUNT/TilePilot.app" /Applications/TilePilot.app
hdiutil detach "$MOUNT" >/dev/null
open -g -a /Applications/TilePilot.app
echo "Published $VERSION, pointed the website at it, and installed it (previous app: $backup/TilePilot.app)."
