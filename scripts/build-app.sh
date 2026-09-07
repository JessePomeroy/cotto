#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
build_jobs="${SOTTO_BUILD_JOBS:-${MURMUR_BUILD_JOBS:-8}}"

if [[ "${1:-}" == "--install" ]] && pgrep -x 'Sotto|Murmur' >/dev/null; then
    printf 'Quit Sotto before building an installed replacement.\n' >&2
    exit 1
fi

signing_override="${SOTTO_SIGNING_IDENTITY:-${MURMUR_SIGNING_IDENTITY:-}}"
if [[ -n "$signing_override" ]]; then
    signing_identity="$signing_override"
else
    # A certificate-backed designated requirement survives code changes; ad-hoc
    # signing binds privacy grants to a CDHash that changes on every rebuild.
    development_identities=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
    identity_count=$(printf '%s\n' "$development_identities" | awk 'NF {n++} END {print n+0}')
    if [[ "$identity_count" == "1" ]]; then
        signing_identity="$development_identities"
        printf 'Using the existing Apple Development signing identity.\n'
    elif [[ "$identity_count" == "0" ]]; then
        signing_identity="-"
        printf 'No development identity found; using ad-hoc signing. Rebuilds may require granting permissions again.\n'
    else
        printf 'Multiple development identities found. Set SOTTO_SIGNING_IDENTITY to the one to use.\n' >&2
        exit 1
    fi
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    printf 'Sotto currently targets Apple Silicon Macs.\n' >&2
    exit 1
fi
if ! macos_sdk=$(xcrun --sdk macosx --show-sdk-path) ||
   ! macos_sdk_version=$(xcrun --sdk macosx --show-sdk-version); then
    printf 'Xcode with the macOS 26 SDK or newer is required to build Sotto.\n' >&2
    exit 1
fi
macos_sdk_major="${macos_sdk_version%%.*}"
if [[ ! "$macos_sdk_major" =~ ^[0-9]+$ ]] || (( macos_sdk_major < 26 )); then
    printf 'Sotto requires the macOS 26 SDK or newer; found %s.\n' "$macos_sdk_version" >&2
    exit 1
fi
if ! command -v cmake >/dev/null; then
    printf 'CMake is required to build the native engine (brew install cmake).\n' >&2
    exit 1
fi
if [[ ! -f vendor/whisper.cpp/CMakeLists.txt ]]; then
    git submodule update --init --recursive
fi

./scripts/download-vad.sh
cmake -S . -B .build/native -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build .build/native --target sotto-engine --parallel "$build_jobs"
./scripts/build-text-engine.sh
# Preserve macOS 14 deployment, but stamp the actual SDK for native appearance.
# Swift's Clang linker needs -isysroot to avoid recording the deployment as SDK.
swift_build_flags=(--scratch-path .build/swift -c release --jobs "$build_jobs"
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$macos_sdk")
swift build "${swift_build_flags[@]}"
swift_bin=$(swift build "${swift_build_flags[@]}" --show-bin-path)

app_path="$project_dir/build/Sotto.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Resources"
cp "$swift_bin/Sotto" "$app_path/Contents/MacOS/Sotto"
cp .build/native/Engine/sotto-engine "$app_path/Contents/Helpers/sotto-engine"
cp .build/text-native/sotto-text-engine "$app_path/Contents/Helpers/sotto-text-engine"
cp .build/text-native/mlx.metallib "$app_path/Contents/Helpers/mlx.metallib"
for bundle in .build/text-native/resources/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$app_path/Contents/Helpers/$(basename "$bundle")"
done
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp .build/models/silero-vad.bin "$app_path/Contents/Resources/silero-vad.bin"
cp vendor/whisper.cpp/LICENSE "$app_path/Contents/Resources/whisper-LICENSE.txt"
cp Resources/*-LICENSE.txt "$app_path/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
swift scripts/make-icon.swift "$project_dir/.build/Sotto.iconset"
iconutil -c icns .build/Sotto.iconset -o "$app_path/Contents/Resources/Sotto.icns"
codesign --force --sign "$signing_identity" --options runtime \
    --identifier dev.davis.murmur.engine "$app_path/Contents/Helpers/sotto-engine"
codesign --force --sign "$signing_identity" --options runtime \
    --identifier dev.davis.murmur.text-engine "$app_path/Contents/Helpers/sotto-text-engine"
codesign --force --sign "$signing_identity" "$app_path/Contents/Helpers/mlx.metallib"
for bundle in "$app_path/Contents/Helpers/"*.bundle; do
    [[ -d "$bundle" ]] || continue
    codesign --force --sign "$signing_identity" "$bundle"
done
# Keep the shipped bundle identity: macOS privacy grants belong to it.
codesign --force --sign "$signing_identity" --options runtime \
    --entitlements Resources/Sotto.entitlements --identifier dev.davis.murmur "$app_path"
codesign --verify --deep --strict "$app_path"
printf '\nBuilt %s\n' "$app_path"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -x 'Sotto|Murmur' >/dev/null; then
        printf 'Quit Sotto from its menu bar menu, then rerun with --install.\n' >&2
        exit 1
    fi
    install_path="$HOME/Applications/Sotto.app"
    legacy_path="$HOME/Applications/Murmur.app"
    if [[ -d "$install_path" ]]; then
        existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_path/Contents/Info.plist")
        if [[ "$existing_id" != "dev.davis.murmur" ]]; then
            printf 'A different app already exists at %s; leaving it untouched.\n' "$install_path" >&2
            exit 1
        fi
    fi
    mkdir -p "$HOME/Applications"
    staging_root=$(mktemp -d "$HOME/Applications/.Sotto-install.XXXXXX")
    backup_root=$(mktemp -d "$project_dir/.build/previous-install.XXXXXX")
    prior_install=""
    installed_new=false
    install_complete=false
    cleanup_install() {
        install_status=$?
        if [[ "$install_complete" != true ]]; then
            if [[ "$installed_new" == true ]]; then rm -rf "$install_path"; fi
            if [[ -n "$prior_install" && -d "$prior_install" ]]; then mv "$prior_install" "$install_path"; fi
        fi
        rm -rf "$staging_root"
        return "$install_status"
    }
    trap cleanup_install EXIT
    ditto "$app_path" "$staging_root/Sotto.app"
    codesign --verify --deep --strict "$staging_root/Sotto.app"
    if [[ -d "$install_path" ]]; then
        prior_install="$backup_root/Sotto.app"
        mv "$install_path" "$prior_install"
    fi
    mv "$staging_root/Sotto.app" "$install_path"
    installed_new=true
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    # The generated bundle may already be unregistered on a repeated install.
    # That cleanup is best-effort; registering the installed copy must succeed.
    if ! "$lsregister" -u "$app_path" >/dev/null 2>&1; then
        printf 'Development-bundle cleanup skipped; registering the installed copy.\n' >&2
    fi
    "$lsregister" -f "$install_path"
    install_complete=true
    # Keep the previous app as a rollback copy, while removing a duplicate
    # launcher for the same stable bundle identifier. Data and TCC are untouched.
    if [[ -d "$legacy_path" ]] &&
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_path/Contents/Info.plist" 2>/dev/null)" == "dev.davis.murmur" ]]; then
        "$lsregister" -u "$legacy_path" >/dev/null 2>&1 || true
        mv "$legacy_path" "$backup_root/Murmur.app"
    fi
    printf 'Previous app backup (if any): %s\n' "$backup_root"
    printf 'Installed %s\n' "$install_path"
fi
