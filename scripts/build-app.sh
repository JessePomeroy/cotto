#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -ne 0 ]]; then
    printf 'Usage: scripts/build-app.sh\nBuilds the thin client at build/Sotto Dev.app.\n' >&2
    printf 'Build the independent server with scripts/build-server.sh, then launch both with scripts/run-dev.sh start --skip-build.\n' >&2
    printf 'This development build does not replace the installed Sotto app.\n' >&2
    exit 2
fi
exec "$project_dir/scripts/build-dev-app.sh"
