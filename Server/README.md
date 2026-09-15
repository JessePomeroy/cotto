# Sotto server

The server is an independent HTTP process. It owns model runtimes, shared preferences and dictionary, audio artifacts, transcripts, and history. The Mac app owns microphone/hotkey controls, device preferences, and guarded text insertion. Quitting the app does not stop the server. There is no offline recording queue.

## Local development on macOS

Requirements: Apple Silicon, macOS 14+, Xcode with its Metal compiler, CMake, and Swift 6.2 or newer. The native client currently uses the macOS 26 SDK or newer. Fetch the pinned git submodules with `git submodule update --init --recursive`.

```sh
./scripts/build-server.sh
./scripts/build-dev-app.sh
./scripts/run-dev.sh start --skip-build
```

`run-dev.sh` starts the server on **http://localhost:8391** and opens **build/Sotto Dev.app**. This app has the separate identity `dev.davis.sotto.dev` and visible Dev labels; grant its microphone and Accessibility permissions separately. It contains no model helpers. The installed Sotto app is left untouched.

The runner reuses existing Whisper weights at `~/Library/Application Support/Murmur/Models/ggml-large-v3-turbo.bin` and MLX Qwen weights at `~/.murmur/models/Qwen3-4B-Instruct-2507-MLX-4bit` when present. It does not copy old sessions, preferences, or credentials. Set `SOTTO_SPEECH_MODEL` and `SOTTO_TEXT_MODEL` to override model locations. Models are loaded and verified by the server; downloading the small pinned Silero VAD is part of the build.

- Persistent dev data: `.local/server`, independent of the client.
- Server output: `.local/server.log`; logs must not contain transcript/audio contents or tokens.
- Server PID: `.local/server.pid`.
- Check: `./scripts/run-dev.sh status`.
- Stop: `./scripts/run-dev.sh stop`.
- Rebuild and restart: `./scripts/run-dev.sh restart`.

The runner waits for HTTP reachability. The app then displays model warming/readiness before recording is admitted. Recording requires the server to accept a generation. A complete upload continues processing if the client disconnects; partial uploads expire, and reconnecting never pastes an old result.

## Standalone runner

`build/server` contains the server executable, native helpers, VAD model, and required resources. Large Whisper/Qwen weights and user data remain outside the distribution. Keep the `helpers` directory intact: the macOS MLX helper needs its adjacent Metal library and resource bundles.

```sh
./build/server/sotto-server \
  --host 127.0.0.1 --port 8391 \
  --data-dir /absolute/path/to/sotto-data \
  --speech-helper "$PWD/build/server/helpers/sotto-engine" \
  --speech-model /absolute/path/to/ggml-large-v3-turbo.bin \
  --vad-model "$PWD/build/server/resources/silero-vad.bin" \
  --proof-helper "$PWD/build/server/helpers/sotto-text-engine" \
  --proof-model /absolute/path/to/Qwen3-4B-Instruct-2507-MLX-4bit
```

Use the Qwen GGUF path instead for Linux. Add `--dev` to identify a development server in health responses. `--token-file /absolute/path/to/token` reads a bearer token from a file rather than process arguments. Nonloopback listeners require a token. The client accepts configured HTTP or HTTPS endpoints. Use HTTPS for public hosting; HTTP can run over localhost or a private encrypted Tailscale connection. The app's server URL and credential are device settings.

The same options accept environment variables:

| Option | Environment |
| --- | --- |
| `--host`, `--port` | `SOTTO_SERVER_HOST`, `SOTTO_SERVER_PORT` |
| `--data-dir`, `--token-file` | `SOTTO_SERVER_DATA_DIR`, `SOTTO_SERVER_TOKEN_FILE` |
| `--speech-helper`, `--speech-model` | `SOTTO_ENGINE_PATH`, `SOTTO_SPEECH_MODEL` |
| `--vad-model` | `SOTTO_VAD_PATH` |
| `--proof-helper`, `--proof-model` | `SOTTO_TEXT_ENGINE_PATH`, `SOTTO_TEXT_MODEL` |

Use launchd on macOS or systemd/container supervision on Linux to start the runner at boot. These scripts do not install a service. Keep the data directory on persistent storage and back it up together with shared preferences. Only one server process may own a data directory at a time.

## Linux builds

The portable Swift HTTP service and both C++ helpers build on Linux x86_64 and ARM64. Whisper uses whisper.cpp; proofreading uses the pinned Qwen3-4B-Instruct-2507 Q4_K_M GGUF through llama.cpp. macOS always packages the native Swift MLX proof helper. The two C++ projects build separately because they carry separate ggml versions.

```sh
# Build a CPU package for smoke checks.
SOTTO_CUDA=OFF ./scripts/build-server.sh

# Build on a Linux host with the CUDA toolkit and a compatible NVIDIA driver.
SOTTO_CUDA=ON ./scripts/build-server.sh
```

`SOTTO_BUILD_JOBS` sets build concurrency. `SOTTO_NATIVE=OFF` disables compilation for only the build host's CPU. For cross-host CUDA builds, set `SOTTO_CUDA_ARCHITECTURES` explicitly for the destination GPU. CPU operation is a compatibility fallback, not a claim that CPU latency meets the dictation target. CUDA architecture/driver support and end-to-end latency must be validated on the eventual GPU host.

Validate a packaged GGUF helper using synthetic transcripts with `python3 scripts/test-llama-engine.py --engine build/server/helpers/sotto-text-engine --model /absolute/path/to/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`. It checks protocol bounds, correction isolation, literal role markers, clean shutdown, and parent-death termination. The server's rewrite policy remains necessary: different Qwen quantizations can rewrite digits as words, which the policy rejects in favor of the original transcript.

## Containers

Build from the repository root after initializing submodules:

```sh
docker build -f Server/Dockerfile --target cpu -t sotto-server:cpu .
docker build -f Server/Dockerfile --target cuda \
  --build-arg CUDA_ARCHITECTURES=121 -t sotto-server:cuda .
```

The CUDA example targets a GB10; select architectures/toolkit appropriate to the host. `SWIFT_IMAGE`, `CUDA_IMAGE`, and `BUILD_JOBS` are overridable build arguments. The CUDA target requires NVIDIA Container Toolkit and `--gpus all` at runtime. Native Metal remains the path for macOS inference; a Linux container on a Mac does not gain Metal access.

Run the CPU image with existing model files and a token file; for a GPU host substitute the CUDA image and add `--gpus all`:

```sh
docker run --rm --name sotto-server \
  -p 127.0.0.1:8391:8391 \
  --mount type=volume,source=sotto-data,target=/data \
  --mount type=bind,source=/absolute/path/to/models,target=/models,readonly \
  --mount type=bind,source=/absolute/path/to/token,target=/run/secrets/sotto-token,readonly \
  sotto-server:cpu
```

The model directory must contain `ggml-large-v3-turbo.bin` and `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`. The container runs as UID 10001; mounted token/model files must be readable by that user, and a bind-mounted `/data` must be writable. The named volume in the example preserves sessions across container replacement. The health check confirms HTTP availability, while `/v1/health` reports inference readiness separately.

See `docs/client-server-contract.md` in the repository for the HTTP upload, progress, shared history, and preference contract. No migration or importer is included.
