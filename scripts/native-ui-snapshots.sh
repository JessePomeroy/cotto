#!/usr/bin/env bash
set -euo pipefail

# Offscreen native SwiftUI previews with synthetic state only. This does not
# launch Sotto, show windows, touch the clipboard, or open audio hardware.
# Offscreen AppKit does not fully composite sidebar vibrancy or desktop glass;
# use live screenshots for final full-window appearance and screen positioning.
#
#   scripts/native-ui-snapshots.sh /private/tmp/sotto-after
#   scripts/native-ui-snapshots.sh --baseline <sotto-revision> /private/tmp/sotto-before
# For pre-Sotto comparisons, use this script from the corresponding revision.

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline=""
if [[ "${1:-}" == "--baseline" ]]; then
    [[ $# -ge 2 ]] || { echo "--baseline requires a Git revision" >&2; exit 2; }
    baseline="$2"
    shift 2
fi
[[ $# -le 1 ]] || { echo "Usage: $0 [--baseline revision] [absolute-output-directory]" >&2; exit 2; }
output="${1:-$(mktemp -d "${TMPDIR:-/private/tmp}/sotto-native-previews.XXXXXX")}"
[[ "$output" == /* ]] || { echo "Use an absolute output directory." >&2; exit 2; }
mkdir -p "$output"
work="$(mktemp -d "${TMPDIR:-/private/tmp}/sotto-native-snapshots.XXXXXX")"
trap 'rm -rf "$work"' EXIT
source_root="$project_root"

if [[ -n "$baseline" ]]; then
    source_root="$work/source"
    mkdir "$source_root"
    git -C "$project_root" archive "$baseline" | tar -x -C "$source_root"
    # Pre-0.13 revisions use the original module names. Run their own isolated
    # harness instead of copying a Sotto-module test into a Murmur package.
    if [[ -f "$source_root/Sources/Murmur/Views/SottoBrand.swift" ]]; then
        "$source_root/scripts/native-ui-snapshots.sh" "$output"
        exit 0
    fi
    if [[ ! -f "$source_root/Sources/Sotto/Views/SottoBrand.swift" ]]; then
        printf 'The current preview harness needs Sotto views. Run the preview script from the pre-Sotto revision for historical comparisons.\n' >&2
        exit 2
    fi
    cp "$project_root/Tests/SottoTests/ViewSnapshotTests.swift" "$source_root/Tests/SottoTests/ViewSnapshotTests.swift"
    # Apply the same preview-only constructor seam to the archived source. No
    # design changes are copied into the baseline. Fail if it stops matching.
    python3 - "$source_root" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / 'Sources/Sotto/SottoController.swift'
source = path.read_text()
if 'init(configuration: ConfigurationStore, startServices: Bool = true)' not in source:
    replacements = [
        ('@Published var permissions = PermissionSnapshot.capture()', '@Published var permissions: PermissionSnapshot'),
        ('private let modelStore = ModelStore()', 'private let modelStore: ModelStore'),
        ('init(configuration: ConfigurationStore) {\n        self.configuration = configuration',
         'init(configuration: ConfigurationStore, startServices: Bool = true) {\n'
         '        self.configuration = configuration\n'
         '        permissions = startServices ? PermissionSnapshot.capture()\n'
         '            : PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: false)\n'
         '        modelStore = ModelStore(paths: startServices ? SottoPaths()\n'
         '            : SottoPaths(root: configuration.url.deletingLastPathComponent().appendingPathComponent("preview-models")))'),
        ('textCorrection = TextCorrectionService(configuration: configuration)',
         'textCorrection = TextCorrectionService(configuration: configuration, inspectOnInit: startServices)'),
        ('        hotkey.key = shortcut\n        bindServices()',
         '        hotkey.key = shortcut\n        guard startServices else { return }\n        bindServices()'),
    ]
    for old, new in replacements:
        if source.count(old) != 1:
            raise SystemExit('Baseline does not match the preview constructor seam: ' + old)
        source = source.replace(old, new, 1)
    path.write_text(source)

# Expose only the actual detail view to @testable previews; preserve its design.
window_path = root / 'Sources/Sotto/Views/SottoWindowView.swift'
window = window_path.read_text()
window_path.write_text(window.replace('private struct DictationPage: View', 'struct DictationPage: View', 1))
if 'var showMicrophone: () -> Void' in window:
    test_path = root / 'Tests/SottoTests/ViewSnapshotTests.swift'
    test = test_path.read_text()
    current = 'DictationPage(controller: controller, showModel: {}, showPreferences: {})'
    baseline = 'DictationPage(controller: controller, showModel: {}, showMicrophone: {}, showPreferences: {})'
    if test.count(current) != 1:
        raise SystemExit('Snapshot detail fixture no longer matches its baseline adapter.')
    test_path.write_text(test.replace(current, baseline, 1))
PY
fi

export SOTTO_SNAPSHOT_DIR="$output"
export CLANG_MODULE_CACHE_PATH="$work/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$work/swift-module-cache"
if ! swift test --package-path "$source_root" --scratch-path "$work/build" \
    --cache-path "$work/cache" \
    --filter ViewSnapshotTests/testGenerateNativePreviewsWhenRequested \
    > "$output/native-preview-test.log" 2>&1; then
    tail -n 100 "$output/native-preview-test.log" >&2
    exit 1
fi
printf 'Native preview images: %s\n' "$output"
tail -n 12 "$output/native-preview-test.log"
