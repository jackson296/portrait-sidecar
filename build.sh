#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
app_path="${1:-$project_dir/build/PortraitSidecar.app}"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/portrait-sidecar.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
staged_app="$stage_dir/PortraitSidecar.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$(dirname "$app_path")"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
  -import-objc-header "$project_dir/Source/VirtualDisplay.h" \
  "$project_dir"/Source/*.swift \
  -o "$staged_app/Contents/MacOS/PortraitSidecar" \
  -framework Cocoa -framework ScreenCaptureKit -framework CoreImage -framework CoreGraphics -framework MetalKit
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
cp "$project_dir/Assets/AppIcon.png" "$project_dir/Assets/AppIcon.icns" "$staged_app/Contents/Resources/"
xattr -cr "$staged_app"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$staged_app"
codesign --verify --deep --strict "$staged_app"
# Replace only this app bundle; the surrounding destination is never removed.
if [[ -d "$app_path" ]]; then
  previous_app="${app_path%.app}.previous.app"
  if [[ -e "$previous_app" ]]; then
    printf 'Move the previous backup out of the way first: %s\n' "$previous_app" >&2
    exit 1
  fi
  mv "$app_path" "$previous_app"
fi
ditto --norsrc "$staged_app" "$app_path"
printf 'Built %s\n' "$app_path"
