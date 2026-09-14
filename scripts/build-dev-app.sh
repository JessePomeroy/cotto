#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The desktop client requires macOS.\n' >&2
    exit 1
fi
build_jobs="${SOTTO_BUILD_JOBS:-8}"
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
swift_flags=(--scratch-path .build/client-swift -c release --jobs "$build_jobs" --product Sotto
    --force-resolved-versions
    -Xswiftc -DSOTTO_DEV_BUILD
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$macos_sdk")
swift build "${swift_flags[@]}"
swift_bin=$(swift build "${swift_flags[@]}" --show-bin-path)

app_path="$project_dir/build/Sotto Dev.app"
mkdir -p build
staging_dir=$(mktemp -d "$project_dir/build/.dev-app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Sotto Dev.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$swift_bin/Sotto" "$staged_app/Contents/MacOS/Sotto"
cp Resources/Info-Dev.plist "$staged_app/Contents/Info.plist"
swift scripts/make-icon.swift "$project_dir/.build/SottoDev.iconset"
iconutil -c icns .build/SottoDev.iconset -o "$staged_app/Contents/Resources/Sotto.icns"

signing_identity="${SOTTO_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    identities=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
    identity_count=$(printf '%s\n' "$identities" | awk 'NF {n++} END {print n+0}')
    if [[ "$identity_count" == 1 ]]; then signing_identity="$identities"; else signing_identity=-; fi
fi
codesign --force --sign "$signing_identity" --options runtime \
    --entitlements Resources/Sotto.entitlements --identifier dev.davis.sotto.dev "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [[ -d "$app_path" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
    if [[ "$existing_id" != dev.davis.sotto.dev ]]; then
        printf 'Another app occupies %s; leaving it untouched.\n' "$app_path" >&2
        exit 1
    fi
    rm -rf "$app_path"
fi
mv "$staged_app" "$app_path"
printf '\nBuilt %s\n' "$app_path"
