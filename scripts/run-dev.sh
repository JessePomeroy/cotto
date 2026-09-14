#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
action="${1:-start}"
if [[ "$action" == --skip-build ]]; then action=start; skip_build=true; else skip_build=false; fi
if [[ "${2:-}" == --skip-build ]]; then skip_build=true; fi
server_binary="$project_dir/build/server/sotto-server"
state_dir="$project_dir/.local"
pid_file="$state_dir/server.pid"
log_file="$state_dir/server.log"
server_port="${SOTTO_SERVER_PORT:-8391}"
client_dir="$state_dir/client"
mkdir -p "$state_dir"
chmod 700 "$state_dir"

launch_client() {
    [[ "$(uname -s)" == Darwin ]] || return 0
    local client_app="$project_dir/build/Sotto Dev.app"
    if [[ ! -x "$client_app/Contents/MacOS/Sotto" ]]; then
        printf 'Build the client with scripts/build-dev-app.sh; the server remains running.\n' >&2
        return 1
    fi
    mkdir -p "$client_dir"
    chmod 700 "$client_dir"
    # LaunchServices does not inherit the shell environment. Pass only the
    # workspace preference root and the local endpoint; credentials use Keychain.
    open --env "SOTTO_CLIENT_DATA_DIR=$client_dir" \
        --env "SOTTO_SERVER_URL=http://127.0.0.1:$server_port" "$client_app"
}

server_pid=""
is_running() {
    [[ -f "$pid_file" ]] || return 1
    read -r server_pid < "$pid_file"
    [[ "$server_pid" =~ ^[0-9]+$ && "$server_pid" -gt 1 ]] || return 1
    kill -0 "$server_pid" 2>/dev/null || return 1
    # A stale PID file must never target an unrelated process.
    case "$(ps -p "$server_pid" -o command=)" in
        "$server_binary "*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_server() {
    if ! is_running; then
        rm -f "$pid_file"
        printf 'The dev server is stopped.\n'
        return
    fi
    kill -TERM "$server_pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if is_running; then
        printf 'The dev server is still stopping (PID %s). See %s.\n' "$server_pid" "$log_file" >&2
        return 1
    fi
    rm -f "$pid_file"
    printf 'Stopped the dev server.\n'
}

case "$action" in
    stop) stop_server; exit 0 ;;
    status)
        if is_running; then
            printf 'Dev server PID %s: http://localhost:%s\n' "$server_pid" "$server_port"
            curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$server_port/v1/health"
            printf '\n'
        else
            printf 'The dev server is stopped.\n'
        fi
        exit 0 ;;
    restart) stop_server ;;
    start) ;;
    *) printf 'Usage: %s [start|stop|status|restart] [--skip-build]\n' "$0" >&2; exit 2 ;;
esac

if is_running; then
    printf 'Dev server already running: http://localhost:%s (PID %s).\n' "$server_port" "$server_pid"
    launch_client
    exit 0
fi
rm -f "$pid_file"
if [[ "$skip_build" != true ]]; then
    ./scripts/build-server.sh
    if [[ "$(uname -s)" == Darwin ]]; then ./scripts/build-dev-app.sh; fi
fi
if [[ ! -x "$server_binary" ]]; then
    printf 'Build the server first with scripts/build-server.sh.\n' >&2
    exit 1
fi

speech_model="${SOTTO_SPEECH_MODEL:-}"
proof_model="${SOTTO_TEXT_MODEL:-}"
if [[ "$(uname -s)" == Darwin ]]; then
    # Reuse model weights only. User recordings, preferences, and credentials
    # are never imported from the installed app.
    speech_model="${speech_model:-$HOME/Library/Application Support/Murmur/Models/ggml-large-v3-turbo.bin}"
    proof_model="${proof_model:-$HOME/.murmur/models/Qwen3-4B-Instruct-2507-MLX-4bit}"
fi
if [[ ! -f "$speech_model" || ! -e "$proof_model" ]]; then
    printf 'Set SOTTO_SPEECH_MODEL and SOTTO_TEXT_MODEL to installed Whisper and Qwen weights.\n' >&2
    exit 1
fi
server_args=(--host 127.0.0.1 --port "$server_port" --dev
    --data-dir "${SOTTO_SERVER_DATA_DIR:-$state_dir/server}"
    --speech-helper "${SOTTO_ENGINE_PATH:-$project_dir/build/server/helpers/sotto-engine}"
    --speech-model "$speech_model"
    --vad-model "${SOTTO_VAD_PATH:-$project_dir/build/server/resources/silero-vad.bin}"
    --proof-helper "${SOTTO_TEXT_ENGINE_PATH:-$project_dir/build/server/helpers/sotto-text-engine}"
    --proof-model "$proof_model")
if [[ -n "${SOTTO_SERVER_TOKEN_FILE:-}" ]]; then server_args+=(--token-file "$SOTTO_SERVER_TOKEN_FILE"); fi
umask 077
nohup "$server_binary" "${server_args[@]}" >> "$log_file" 2>&1 < /dev/null &
server_pid=$!
printf '%s\n' "$server_pid" > "$pid_file"
for ((attempt = 0; attempt < 100; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        rm -f "$pid_file"
        printf 'The dev server exited during startup. See %s.\n' "$log_file" >&2
        exit 1
    fi
    if curl --fail --silent --max-time 1 "http://127.0.0.1:$server_port/v1/health" > /dev/null; then
        printf 'Dev server: http://localhost:%s (PID %s)\nLog: %s\n' "$server_port" "$server_pid" "$log_file"
        launch_client
        exit 0
    fi
    sleep 0.1
done
printf 'The dev server is starting slowly. See %s; use scripts/run-dev.sh status to check it.\n' "$log_file" >&2
exit 1
