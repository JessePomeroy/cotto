# Local inference server

The Linux server is a Bun-compiled TypeScript/Fastify executable. It supervises
persistent C++ Whisper and optional Qwen helpers and owns generation history.
It does not capture audio or insert text into applications. No Swift, MLX, Metal,
or macOS tooling is part of this fork's build or runtime.

## Models

Models are explicit downloads, not runtime dependencies fetched automatically.
Keep them outside Git. Production verifies the immutable identities in
[`model-pins.ts`](src/inference/model-pins.ts).

### Whisper

The pinned `ggml-large-v3-turbo.bin` is approximately 1.62 GB. When you are ready
to download it:

```zsh
SOTTO_MODEL_DIR="$PWD/.local/models" ./scripts/download-model.sh
```

The script verifies its pinned SHA-256 before installation. The server package
also includes a separately pinned Silero VAD model (approximately 865 KB), fetched
by `scripts/download-vad.sh` during the complete helper build.

### Qwen

The supported cleanup model is Qwen3-4B-Instruct-2507 Q4_K_M, approximately 2.50 GB.
Download it explicitly from the pinned conversion and verify the checksum:

```zsh
mkdir -p .local/models
curl --fail --location --output .local/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
printf '%s  %s\n' \
  3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597 \
  .local/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf | sha256sum --check
```

Qwen is controlled by the shared `textCorrectionEnabled` preference. Fresh server
preferences enable it; disabling it keeps deterministic dictionary/list processing
and allows speech-only readiness. The compact desktop currently exposes engine
health, not a shared-preferences editor. Use the revision-safe preferences API to
change server settings; see [HTTP contract](../docs/client-server-contract.md).

## Build

Requirements: Linux x64 or arm64, Bun 1.4.2, C/C++ toolchain, CMake, Git, curl,
pkg-config, and libcurl development headers. CUDA is optional and requires a
matching toolkit and NVIDIA driver. No model inference runs during these builds.

```zsh
bun install --frozen-lockfile
git submodule update --init --recursive
./scripts/build-server.sh                      # complete CPU package; fetches VAD
SOTTO_CUDA=ON ./scripts/build-server.sh         # optional CUDA package
```

Output: `build/server/`, containing `sotto-server`, `helpers/`, resources, and
notices. Keep the package together. Large model files and user data live outside
it. Installed server packages do not require Bun, Node, Python, or Swift.

**Builds replace `build/server`.** Use a separate checkout when building beside a
running package. The build script does not restart services or migrate data.
`SOTTO_SKIP_NATIVE=1` can reuse explicitly provided `SOTTO_ENGINE_PATH`,
`SOTTO_TEXT_ENGINE_PATH`, and `SOTTO_VAD_PATH` instead of rebuilding helpers.

Coordinator-only builds:

```zsh
bun run build:server --outfile "$PWD/.local/server-build/sotto-server"
bun run build:server --all                    # Linux x64 and arm64 coordinators
```

Native helpers still need matching platform builds. x64 coordinators use Bun's
baseline CPU target; portable helper builds can use `SOTTO_NATIVE=OFF`.
`SOTTO_CUDA_ARCHITECTURES` and `SOTTO_BUILD_JOBS` control CUDA targets and build
parallelism. See the [Dockerfile](Dockerfile) for Linux CPU/CUDA build targets.

## Run

The CLI defaults to port 8391. The Linux desktop and generated development services
use 8392; specify matching endpoints when starting manually:

```zsh
./build/server/sotto-server --dev --host 127.0.0.1 --port 8392 \
  --data-dir "$PWD/.local/server" \
  --speech-helper "$PWD/build/server/helpers/sotto-engine" \
  --speech-model "$PWD/.local/models/ggml-large-v3-turbo.bin" \
  --vad-model "$PWD/build/server/resources/silero-vad.bin" \
  --proof-helper "$PWD/build/server/helpers/sotto-text-engine" \
  --proof-model "$PWD/.local/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
```

Helpers stay warm. `SOTTO_SPEECH_DEVICE=cpu|gpu` selects Whisper execution;
`SOTTO_TEXT_GPU_LAYERS=0..99` and `SOTTO_TEXT_KV_TYPE=f16|q8_0` control Qwen offload
and cache representation. These settings are inherited from the server environment;
they do not change the pinned model. Benchmark latency, memory, and output quality
before selecting a GPU profile. CPU operation is supported.

Configuration also accepts the corresponding `SOTTO_*` environment variables;
`--help` lists the CLI. The server never downloads models or imports personal data
on startup. No recordings are queued while inference is unavailable.

## Storage and privacy

One process may own a `--data-dir`, enforced with Linux libc `flock`. Never unlink
its lock file to bypass a running owner. Back up preferences and generations
together; see [storage](../docs/architecture.md#storage).

Completed transcripts and inference audio persist until explicitly deleted.
Original audio defaults on; its retention preference affects future takes only.
Personal words are snapshotted per take, not merged into shared preferences, but
remain in generation metadata. The server is not a per-account multi-user service.

## Remote access

The desktop client currently accepts loopback endpoints only. The server can
serve other API clients remotely when explicitly configured. Nonloopback bindings
require `--token-file` with at least 32 non-whitespace characters. Use HTTPS or a
private encrypted network; never put credentials in URLs. Health is lightweight
and contains no transcript data. Host/Origin validation and bearer checks protect
data routes, but they do not create user-specific history ACLs.

The Docker runtime expects persistent `/data`, read-only `/models`, and a token
file at `/run/secrets/sotto-token`. GPU containers require NVIDIA Container Toolkit
and an explicit `--gpus` configuration. Container builds do not configure the
native desktop's permissions or startup.

## Verify

```zsh
bun run fmt:check
bun run check
bun run test
bun run generate:api --check
bun Server/scripts/smoke.ts --executable .local/server-build/sotto-server
```

The compiled smoke test uses a temporary archive, isolated loopback port, and
missing-model fixtures; it performs no inference. Default tests use fake helpers
and do not contact credentialed providers. Real acoustic/Qwen checks are separate,
explicit opt-ins; see [testing](../docs/linux/TESTING.md).

- [API schema](api/openapi.yaml) and [generation](api/README.md)
- [Whisper protocol](../Engine/README.md)
- [Qwen protocol](../TextEngine/README.md)
- [Text correction policy](../docs/text-correction.md)
