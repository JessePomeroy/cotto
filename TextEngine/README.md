# Qwen helper

The server packages `sotto-text-engine`, a native Linux C++ helper using llama.cpp.
It runs Qwen3-4B-Instruct-2507, serves JSON-lines requests, and remains loaded between
requests. It reads local model files and never opens a microphone, network connection,
or chat session.

Build with `scripts/build-server.sh`; see [model setup](../Server/README.md#models).
The helper has a separate CMake project because its ggml version differs from Whisper's.

## Protocol

After verifying/loading the model, the helper emits a `ready` JSON object with `engineVersion`. Requests and responses are newline-delimited UTF-8 JSON:

```json
{"type":"correct","id":"example","text":"i use code ex.","terms":["Codex"],"language":"en","systemPrompt":"Return only the cleaned transcript. Preserve wording and use preferred names only when they match."}
{"type":"result","id":"example","text":"I use Codex.","elapsed":0.2}
```

An error contains `type: "error"`, `message`, and the request `id` when available. Failed requests never return a partial rewrite. The server supplies the snapshotted cleanup prompt on every request and validates each proposed result before delivery. Helpers have no fallback behavior prompt.

## Bounds and lifecycle

- Request: 64 KiB; transcript: 24 KiB; nonempty system prompt: 4 KiB. Up to 256 terms, 256 bytes each, 16 KiB total. Server policy further caps text at 6,000 characters and model hints at 80 terms/4 KiB.
- Context: 8,192 tokens including role framing, prompt, JSON input, and the 2,048-token output reservation. Greedy decoding; overflow, output exhaustion, and empty output fail rather than truncate.
- Inference: 15-second helper deadline. The server resets a hung helper at 18 seconds and bounds proofreading startup at 30 seconds.
- User text and custom prompts cannot introduce structural control-token IDs. Semantic model mistakes are still possible; [rewrite guards](../docs/text-correction.md#preservation-checks) determine whether output is accepted.
- Request state is cleared after each correction. Cancellation of active work terminates the process. Quit, stdin EOF, and parent death release the model. The server retains idle warm helpers.

Diagnostics use stderr and omit transcripts. The server drains them without storing them.

## Linux fork runtime settings

The Linux fork adds two opt-in environment settings to the GGUF helper, inherited
from the server process. `SOTTO_TEXT_GPU_LAYERS` accepts 0–99 (0 requests CPU
execution; default 99). `SOTTO_TEXT_KV_TYPE` accepts `f16` (upstream default) or
`q8_0` (smaller, quantized attention cache). Invalid values fail before model load.
These settings retain the upstream 8,192-token context and all request/output
bounds. They do not alter the model file. Partial offload trades latency for GPU
headroom when Whisper, Qwen and the desktop share an 8 GB GPU. Validate cleanup
quality and latency before selecting a profile; changing the cache representation
can change generated text. The helper version includes the `linux1` suffix to
distinguish this fork's runtime configuration support.

## Verify

With a built package and `SOTTO_TEXT_MODEL` set to its GGUF model file:

```sh
./scripts/test-corrections.sh
```

This runs the Linux helper harness and exports the canonical default from
`build/server/sotto-server`. To test a custom prompt, add `--prompt /absolute/path/to/prompt.txt`;
the file is used exactly, including trailing newlines. Use `--server` when running
`test-llama-engine.py` directly against another server build.

The suites use synthetic text to check corrections, numbers/negations, names, literal role markers, bounds, request isolation, and process shutdown. Provider-free Bun tests cover server lifecycle and output validation without model files. These checks do not establish microphone or cross-app insertion behavior.
