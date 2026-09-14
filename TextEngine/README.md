# Local text engine

`sotto-text-engine` is an independent, stdio-only **native Swift MLX** helper. It
loads the non-thinking Qwen3-4B-Instruct-2507 MLX 4-bit model and proofreads one
transcript at a time. No Python interpreter, HTTP server, network inference,
shell tools, chat history, or transcript logging is included. The app explicitly
downloads or imports the separately pinned six-file model directory; complete
size/hash verification precedes use. The full artifact manifest and legacy GGUF
details are in [text correction](../docs/text-correction.md).

Build from the repository root with `scripts/build-text-engine.sh`. The separate
Swift package pins **mlx-swift 0.31.4**, **mlx-swift-lm 3.31.4**, and
**swift-transformers 1.3.0**; `Package.resolved` pins the transitive graph. The app
build packages and signs the helper, adjacent `mlx.metallib`, and dependency
resource bundles. Xcode compiles the Metal shaders; a plain `swift build` is not
the complete runtime packaging path. If the compiler is missing, install the
matching component with `xcodebuild -downloadComponent MetalToolchain`.
Runtime loading does not require DerivedData.
Whisper remains in its independent C++ helper. The retained `murmur-text-engine`
CMake target is the historical llama.cpp/GGUF benchmark helper, not the shipping
MLX executable. Legacy GGUF weights are not loaded or silently removed by MLX.

The model argument is a directory, normally
`~/.murmur/models/Qwen3-4B-Instruct-2507-MLX-4bit/`, not a repository ID or GGUF.
Local tokenizer configuration is decoded directly from verified files; no Hub
downloader or remote-code/tokenizer fallback is used. SwiftPM networking occurs
only while resolving build dependencies, not while running the helper.

## Protocol

After loading, the helper emits a single JSON line:

```json
{"type":"ready","engineVersion":"mlx-swift-0.31.4-lm-3.31.4-sotto2"}
```

Requests and responses are newline-delimited UTF-8 JSON:

```json
{"type":"correct","id":"example","text":"i use code ex.","terms":["Codex"],"language":"en","systemPrompt":"Return the corrected transcript only. Preserve all spoken content and use preferred names when they match."}
{"type":"result","id":"example","text":"I use Codex.","elapsed":0.2}
```

An error has `type`, `message`, and the request `id` when one was valid. A failed
request never returns a partial rewrite. The app keeps the deterministic
transcript on errors or when its additional content-preservation checks reject a
rewrite. Dictionary aliases and list continuity remain server-owned rules, not
model memory.

## Bounds and lifecycle

- 64 KiB per request, 24 KiB transcript, a required nonempty 4 KiB system prompt,
  and at most 256 preferred terms totaling 16 KiB, 256 bytes per term. The server imposes a smaller 6,000-character transcript
  cap and limits dictionary hints before calling the helper.
- 8,192-token context including prompt, JSON, role framing, and the reserved
  2,048 generated-token allowance; greedy decoding. Oversized
  context, output exhaustion, and empty output fail rather than truncate text.
- 15-second inference deadline inside the helper, followed by a 2-second hard
  process-exit backstop if GPU work cannot settle; the Swift client resets a hung
  helper at 18 seconds and bounds model startup at 30 seconds.
- The server supplies its snapshotted, user-editable cleanup prompt on every
  request. Helpers have no fallback behavior prompt. A separate raw
  tokenizer excludes all added control tokens from both custom system text and JSON; trusted
  ChatML framing is tokenized separately. Literal role markers therefore do not
  become structural control IDs. This is not a guarantee against semantic prompt
  injection or model mistakes; the app still validates output before accepting it.
- KV state is cleared after each request. Canceling active loading/inference
  terminates the process; a canceled take leaves an already-idle warm model alone.
  The app's memory policy unloads it on idle, and a parent-death watchdog exits
  even if the app crashes during inference.
- Diagnostics are drained and not retained by the app. No audio is read here.

## Verification

`python3 scripts/test-text-engine.py` checks the real model using synthetic text,
without a microphone or user history. Metal access is required. Swift fake-helper
tests separately cover shared startup, task cancellation, timeouts, stale replies,
and unload/reload races without model files or network access.

Tests and `scripts/benchmarks/benchmark-corrections.py` load the single canonical
default using `.build/debug/sotto-server --print-default-proofreading-prompt`.
Use `--server PATH` for another server executable, or `--prompt FILE` to exercise
an explicit custom prompt on either MLX or llama.cpp. Benchmark results record
the exact prompt's SHA-256 hash.

The [historical model comparison](../docs/benchmarks/2026-09-04/README.md) used
Python MLX-LM and different quantizations from the legacy GGUF helper; it is not
a native Swift startup/performance test.

The native names fixture permits a lowercase **i** in one sentence while
keeping preferred-name spellings and all remaining words exact. The apology
fixture permits MLX to omit the optional "that" in "I am sorry that the server
is offline" while retaining the apology and its meaning. Capitalization,
homophone overcorrection, and dictated-instruction handling remain known
[correction limitations](../docs/text-correction.md#correction-limitations).
Synthetic checks do not establish live microphone or cross-app insertion behavior.
