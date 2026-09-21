#!/usr/bin/env bash
# Provider-free gates for the actively supported TypeScript server and Linux client.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ -x "$root/.local/tools/bun-linux-x64/bun" ]; then
  export PATH="$root/.local/tools/bun-linux-x64:$PATH"
fi

linux_ctest() {
  ctest --test-dir build/linux --output-on-failure --no-tests=error "$@"
}

usage() {
  echo "usage: $0 fast | subsystem <desktop|pi|server> | broad" >&2
  exit 2
}

[ $# -ge 1 ] || usage
mode="$1"
shift

case "$mode" in
  fast)
    # Explicit, hermetic tests for the common Linux capture/protocol path.
    linux_ctest -R '^(sotto-linux-core|sotto-personal-dictionary|sotto-generation-protocol|sotto-pi-dictation|sotto-settings-ui)$'
    ;;
  subsystem)
    [ $# -eq 1 ] || usage
    case "$1" in
      desktop) linux_ctest -R '^(sotto-startup-config|sotto-desktop-paste|sotto-desktop-shortcuts|sotto-desktop-tray|sotto-settings-ui)$' ;;
      pi) linux_ctest -R '^(sotto-pi-bridge|sotto-pi-dictation|sotto-recording-status)$' ;;
      server) bun run test ;;
      *) usage ;;
    esac
    ;;
  broad)
    bun run test
    linux_ctest
    ;;
  *) usage ;;
esac
