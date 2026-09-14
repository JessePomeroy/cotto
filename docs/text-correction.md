# Dictionary and text correction

The server applies explicit dictionary rules and optional Qwen proofreading after Whisper speech recognition. Processing is identical at the API boundary on Mac and Linux; only the model runtime differs. The Mac client receives a finished insertion chunk and keeps responsibility for safe cursor delivery.

## Dictionary

Edit named lists under **Server preferences**, then save the shared preferences. Every list is active. A generation snapshots the current dictionary when the server accepts it, so an edit on another Mac affects later takes.

- Preferred spellings normalize capitalization: `minimax` becomes `MiniMax`. Aliases are explicit whole-word/phrase replacements; `mini max` becomes `MiniMax` only when mapped to it.
- Matching is case-insensitive with Unicode word boundaries. Longer phrases take precedence, and replacements do not cascade or change matching substrings inside unrelated identifiers.
- Star priority terms to suggest them first. Whisper packs whole terms into its loaded model’s actual token budget, then reports included/omitted terms. Qwen uses the same dictionary priority order within its separate limits. Omitted terms appear in history details. All dictionary entries still perform exact replacements.
- Prefer narrow phrase aliases such as `off middleware → auth middleware`; a broad `off → auth` alias also corrupts legitimate “turn off.” Vocabulary hints can improve recognition but do not guarantee homophone disambiguation.
- The initial **Personal** list contains **MiniMax** and **Codex**. Explicitly removing them or saving an empty dictionary is respected. There is no fuzzy replacement or automatic learning from editor changes.

Dictionary lists, aliases, priority, recognition hints, the cleanup system prompt, and the proofreading toggle belong to the server's revisioned preferences, not the Mac's device configuration.

## Cleanup instructions

Server preferences provides a fixed-height **Cleanup system prompt** editor and **Reset to default**. Save commits the draft for all clients; current recordings keep their original snapshot. The default asks Qwen to preserve intentional “like,” repetition, and every answer while interpreting explicit spoken corrections such as “orange, erm, yellow.” Custom instructions change cleanup behavior within the content-preservation guards. Disabling Qwen preserves fillers as well as other recognized words.

## Model and runtime

**Qwen3-4B-Instruct-2507** is a 4-billion-parameter, non-thinking instruction model licensed Apache 2.0. Proofreading defaults on. Disabling it preserves Whisper, dictionary rules, and deterministic list formatting.

| Server | Runtime | Pinned artifact |
| --- | --- | --- |
| Apple Silicon macOS | Native Swift MLX | `mlx-community/Qwen3-4B-Instruct-2507-4bit`, revision `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b` |
| Linux x86_64 / ARM64 | llama.cpp, optional CUDA | `unsloth/Qwen3-4B-Instruct-2507-GGUF`, revision `a06e946bb6b655725eafa393f4a9745d460374c9`, `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |

- The MLX snapshot is 2,274,455,727 bytes across six files. Its manifest SHA-256 is `6689706a7d1a746920df5c5d5dc1e8ed3280790a542085d6e3c870c565e77307`. The complete file manifest is defined in [`TextModel.swift`](../Sources/SottoCore/TextModel.swift); all regular files must match before use.
- The GGUF is 2,497,281,120 bytes, SHA-256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`. The server verifies the pinned size/hash before loading.
- Model paths are explicit server configuration. The server does not download weights on demand, and the client has no model download/unload controls.
- The Mac helper pins `mlx-swift 0.31.4`, `mlx-swift-lm 3.31.4`, and `swift-transformers 1.3.0`. It uses its adjacent Metal/resources bundle and needs no Python runtime.

The server warms helpers at startup and keeps models loaded for reuse. A cancelled inference can require warming again. Weight size alone does not establish runtime memory or latency; Linux CUDA support and the dictation target must be checked on the selected GPU host.

## Processing and safeguards

1. Whisper recognizes the complete take with language and bounded preferred-term/vocabulary hints.
2. Mechanical whitespace/model-marker cleanup runs, followed by exact dictionary rules. Hesitation and repair cues remain available to Qwen.
3. The deterministic English list formatter establishes bullets, numbers, and continuation state.
4. Qwen proofreads the new formatted chunk using the server-owned prompt snapshotted for this generation. Dictionary rules run again on its candidate.
5. Rewrite checks accept the candidate or retain the source. The composer calculates insertion and preview text; the client performs guarded delivery.

Standalone numeric answers remain content; repeated numbered items preserve their spoken starting values. Formatting verifies content preservation and falls back to the source if it would lose content.

Proofreading cannot create or advance list state. Checks reject changed list markers/structure, protected quantities, altered negation, lost preferred terms, excessive wording changes, control tokens, and response preambles. A change from digits to words can be rejected to preserve a quantity's original representation. Ordered answer coverage rejects deletion of short answers or whole sentences even when a long paragraph remains. Explicit localized corrections may replace quantities or negations only within a verified abandoned phrase; other words remain protected. Existing list-marker corrections remain subject to the list-state guard.

Because `sorry` can introduce an apology, its deletion exception requires an anchored single-word replacement, a direct quantity replacement, or repeated wording with a negation change. Broader lexical or clause restarts can conservatively fall back to the source; the prompt does not bypass this guard. The other explicit repair cues retain their bounded alignment checks.

Input is bounded to 6,000 characters. Helpers use an 8,192-token context and a 2,048-token output limit. Preferred-term hints are bounded to 80 terms, 4,096 UTF-8 bytes total, and 256 bytes per term. Token/context limits can reject an otherwise short multilingual or vocabulary-heavy input.

Validation also bounds Unicode code units and token-alignment work. Unusually dense Unicode rejects cleanup while retaining the source, instead of overflowing a score or allocating an unbounded alignment matrix.

Missing model files, excessive input, helper failures, timeouts, and rejected candidates preserve the cleaned, dictionary-corrected, list-formatted source. Metadata records `disabled`, `skipped`, `failed`, `rejected`, `unchanged`, or `applied` with the applicable reason and provenance. Empty/list-control-only text does not trigger a model rewrite.

The guards do not prove semantic equivalence. Qwen can still change a homophone incorrectly, miss capitalization, or treat dictated instructions as something to answer. Review important text before sending. Historical benchmark artifacts are research records and do not establish current server latency.

## Data boundary and checks

The proofreader receives the dictated chunk, detected language, bounded preferred terms, and the snapshotted cleanup system prompt. It receives no surrounding document, screenshots, Accessibility handles, clipboard history, or accumulated preview. It does not learn from saved history or later edits. These inputs travel to the selected server and are processed by its native helper over private pipes.

Shared generation metadata retains raw/final text, accepted settings, correction source/proposed/accepted output and verified repair spans, vocabulary selection, outcome/reason, model identity/hash, engine version, and timings when available. See [shared history](local-history.md).

Run `swift test` for portable dictionary/list/rewrite policy and server/client tests. Native helper harnesses exercise protocol and synthetic inputs without opening a microphone:

```sh
python3 scripts/test-text-engine.py \
  --helper build/server/helpers/sotto-text-engine \
  --model /absolute/path/to/Qwen3-4B-Instruct-2507-MLX-4bit \
  --server build/server/sotto-server

# Use the GGUF harness with a packaged Linux helper:
python3 scripts/test-llama-engine.py \
  --engine build/server/helpers/sotto-text-engine \
  --model /absolute/path/to/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  --server build/server/sotto-server
```

There is no legacy desktop transcription/correction CLI or model importer. File-based integration uses the [server HTTP contract](client-server-contract.md).

Audio rechecking for negations Whisper omitted is a [separate follow-up](follow-ups/missing-negation-recognition.md). The current guards compare recognized text; they do not guarantee detection of words missing from ASR.
