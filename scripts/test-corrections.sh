#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
if [[ -z "${SOTTO_TEXT_MODEL:-}" ]]; then
    printf 'Set SOTTO_TEXT_MODEL to your Qwen GGUF file.\n' >&2
    exit 1
fi
exec python3 "$project_dir/scripts/test-llama-engine.py" --engine "$project_dir/build/server/helpers/sotto-text-engine" --model "$SOTTO_TEXT_MODEL" --server "$project_dir/build/server/sotto-server" "$@"
