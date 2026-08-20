#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
derived_dir="$repo_dir/DerivedData"
release_dir="$repo_dir/build/Release"
release_app="$release_dir/CodexDictate.app"
entitlements="$repo_dir/CodexDictate/Resources/CodexDictate.entitlements"

export DEVELOPER_DIR="$developer_dir"
cd "$repo_dir"

xcodebuild -project CodexDictate.xcodeproj -scheme CodexDictate -destination 'platform=macOS' -derivedDataPath "$derived_dir" build
xcodebuild -project CodexDictate.xcodeproj -scheme CodexDictate -destination 'platform=macOS' -derivedDataPath "$derived_dir" test
xcodebuild -project CodexDictate.xcodeproj -scheme CodexDictate -configuration Release -destination 'platform=macOS' -derivedDataPath "$derived_dir" build

mkdir -p "$release_dir"
ditto "$derived_dir/Build/Products/Release/CodexDictate.app" "$release_app"

# Accessibility consent is tied to an app's designated code requirement. An
# ad-hoc signature uses the build's CDHash, so macOS silently invalidates the
# consent after every rebuild. Prefer an existing stable signing identity when
# one is available; callers can override it explicitly for another machine.
signing_identity=${CODEXDICTATE_SIGNING_IDENTITY:-}
if [ -z "$signing_identity" ]; then
  signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' \
    | head -n 1 || true)
fi

if [ -n "$signing_identity" ]; then
  codesign --force --deep --options runtime \
    --entitlements "$entitlements" \
    --sign "$signing_identity" \
    "$release_app"
  echo "Release signed with: $signing_identity"
else
  echo "Warning: no code-signing identity found; Accessibility permission must be re-granted after rebuilds." >&2
fi

codesign --verify --deep --strict "$release_app"
echo "Release app: $release_app"
