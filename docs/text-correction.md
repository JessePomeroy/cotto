# Dictionary and local text correction

Sotto adds two separate steps after speech recognition: explicit personal-dictionary rules and an optional on-device proofreading model. The current backend is a native Swift MLX helper; the earlier 0.8 implementation used llama.cpp/GGUF. Neither reads the surrounding app/document, captures the screen, learns from later edits, or calls a hosted model. Review important text before sending; local does not mean error-free.

## Dictionary

- Open **Dictionary** in the sidebar. The list picker chooses the list to edit; **all lists are active together**. Use **+** for a list, **…** to rename/delete it, and **Add term** for a preferred spelling. Editing and deletion have explicit controls; deletion asks for confirmation.
- The initial **Personal** list contains **MiniMax** and **Codex**. Neither has prefilled aliases. Removing these entries is respected; an explicitly empty dictionary stays empty.
- A preferred spelling normalizes capitalization: `minimax` becomes `MiniMax`. Alternate spellings are explicit whole-word/phrase replacements. For example, adding `mini max` as an alias for `MiniMax` makes that replacement deterministic. Without an alias, the dictionary does not guess that two different spellings mean the same thing; the optional model may separately propose a correction.
- Matches are case-insensitive and respect Unicode word boundaries. They do not rewrite a matching substring inside an unrelated identifier. Longer explicit phrases take precedence, and replacements do not cascade into one another.
- **Additional recognition hints** is the original comma-separated vocabulary setting, moved from Preferences. Preferred dictionary terms join these Whisper hints; aliases are excluded so the recognizer is not encouraged to reproduce a known misspelling.

Lists, terms, and aliases live in the existing `~/.murmur/config.json` watcher. The UI validates the complete dictionary before saving, including conflicting mappings across lists. A recording snapshots the dictionary at key-down; UI or file edits apply to the next take. See [configuration](configuration.md) for limits and JSON examples.

## Optional model and controls

In **Models → Text correction**, **Polish your dictation** is on by default. It requires a separately downloaded model; enabling the switch never downloads one implicitly. Turn it off to keep Whisper, the deterministic dictionary, and list formatting without a generative proofread.

The section shows download/verification state, progress, memory state, and the latest correction outcome. It provides **Download model**, **Cancel**, **Load into memory**, **Unload**, and confirmed model removal. Speech-model controls remain independent. An earlier GGUF download does not satisfy the MLX manifest.

The selected model is the 4-billion-parameter, non-thinking **Qwen3-4B-Instruct-2507**, licensed Apache 2.0. Its size and direct-answer mode suit a bounded local proofreading stage without adding a reasoning transcript. This is a practical first-pass choice, not a claim of winning an exhaustive transcription-correction benchmark. See the [Qwen model card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507).

The [September 4 local MLX comparison](benchmarks/2026-09-04/README.md) is a historical research run of Qwen3, Qwen3.5-2B, LFM2.5-1.2B, and SmolLM3-3B against the then-shipping GGUF helper using synthetic inputs. It used **Python MLX-LM**, not this native Swift helper, and different quantization from GGUF. It informed the approved backend migration but does not establish native startup, memory, or correction latency. Its observed correction/guard limitations still apply; switching backends does not fix semantic errors automatically.

Sotto uses the [mlx-community 4-bit conversion](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/tree/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b), pinned in `Sources/SottoCore/TextModel.swift`:

| Property | Value |
| --- | --- |
| Model ID | `qwen3-4b-instruct-2507-mlx-4bit` |
| Repository | `mlx-community/Qwen3-4B-Instruct-2507-4bit` |
| Revision | `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b` |
| Complete size | 2,274,455,727 bytes, approximately 2.27 GB |
| Manifest SHA-256 | `6689706a7d1a746920df5c5d5dc1e8ed3280790a542085d6e3c870c565e77307` |
| Local directory | `~/.murmur/models/Qwen3-4B-Instruct-2507-MLX-4bit/` |

The complete manifest is:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `model.safetensors` | 2,263,022,417 | `2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f` |
| `config.json` | 938 | `574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849` |
| `tokenizer.json` | 11,422,654 | `aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4` |
| `tokenizer_config.json` | 5,440 | `4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9` |
| `generation_config.json` | 238 | `835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48` |
| `chat_template.jinja` | 4,040 | `40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541` |

All six regular files must match their sizes/hashes before use; missing, unexpected, or symlinked entries are rejected. The manifest identity is the SHA-256 of UTF-8 lines sorted by filename, each containing `filename`, a tab, decimal byte count, a tab, file SHA-256, and a newline. Processing metadata uses this complete artifact identity rather than hashing only the weights: changing tokenizer/configuration files changes the identity too. File size is not a prediction of total RAM.

The native helper pins **mlx-swift 0.31.4**, **mlx-swift-lm 3.31.4**, and **swift-transformers 1.3.0**. It performs tokenization and Metal inference in-process, loads only the verified local directory, and requires no Python, Python packages, Ollama, or server. Build-time SwiftPM dependencies are separate from runtime model downloads.

If present from an earlier installation, the [Unsloth Q4_K_M artifact](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf) is preserved at `~/.murmur/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` as a legacy file (2,497,281,120 bytes; SHA-256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`). The new helper neither loads it nor deletes it when managing the MLX model. Whisper's existing model stays in `~/Library/Application Support/Murmur/Models/`.

## Processing and safeguards

The pipeline is:

1. Whisper recognizes speech using the chosen language and combined preferred-term/legacy hints.
2. Light cleanup runs, followed by the exact dictionary rules.
3. The deterministic English list formatter establishes numbers, bullets, and continuation metadata.
4. The optional local model proofreads the new formatted chunk. The dictionary runs again on its proposal.
5. Conservative checks accept the proposal or keep the source. The existing composer and guarded text-delivery path run afterward.

The model cannot advance list state or invent new markers/numbers: changed markers, item structure, and protected quantities cause fallback. Other checks reject altered negation, lost dictionary terms, excessive wording changes, control tokens, or response preambles. The model can still make a meaning-changing edit that these heuristics miss. They are a safety net, not semantic equivalence checks or a reason to skip review.

Proofreading is bounded to **6,000 input characters**. The helper uses an **8,192-token context** and a **2,048-token output limit**. Preferred-term hints are bounded separately (currently up to 80 terms, 4,096 UTF-8 bytes total, at most 256 bytes per term); the complete validated dictionary still performs deterministic replacements. Token/context limits may reject some otherwise short inputs, especially with long or multilingual terms.

Missing weights, long input, load/inference failures, timeouts, and rejected proposals return the already-cleaned, dictionary-corrected, list-formatted source. The UI records that correction was skipped; it does not discard a usable transcription. Disabling correction reports dictionary-only processing. Empty/list-control-only chunks do not trigger a generative rewrite. Surrounding field/caret safety is rechecked after the extra processing time, immediately before any insertion; a model result never authorizes pasting somewhere else.

## Loading, cancellation, and privacy

- When enabled and installed, the model starts warming while you hold the dictation key. Microphone/HUD startup does not wait for it. This does not pre-open a microphone or add idle listening.
- Both helpers use the same `idleMinutes` setting: unload after a take, after five/fifteen idle minutes, or keep warm until quit. Already-ready models may be reused after a cancelled take; queued loads and active inference are stopped.
- Sleep, lock, and quit cancel work and unload. Memory pressure unloads idle models. Turning correction off unloads it when idle; a take already in progress retains its snapshotted setting.
- `sotto-text-engine` runs native Swift MLX as a local child process over private stdin/stdout pipes. It opens no server/listening port, starts no Python interpreter, and uses no inference network call. Runtime downloading is explicit and limited to the pinned model manifest from Hugging Face.
- The model receives the dictated chunk and bounded preferred terms, not document contents, screenshots, other applications' text, clipboard history, or earlier accumulated previews. It is not trained or fine-tuned on your corrections or saved history.

With history enabled, the raw ASR and final chunk remain in the per-take archive. Optional `textProcessing` metadata records the snapshotted preferred terms and whether dictionary rules changed the text, source/final text, enabled state, result/reason, model identity, engine version, and timing. It does not copy the dictionary's list names or aliases. This includes personal terms from the dictionary and is not separately encrypted. See [local history](local-history.md).

## Correction limitations

- The native helper identifies itself as `mlx-swift-0.31.4-lm-3.31.4-sotto1` and retains the historical production prompt. It can leave sentence capitalization unchanged, including a lowercase **i**. The synthetic quality check accepts either **I** or **i** in one names sentence while retaining exact preferred-name and remaining-word expectations.
- A dictionary hint can cause an unwanted homophone correction, such as changing ordinary “rays cast” to “Raycast cast.” The heuristic guard has accepted that meaning-changing edit in the historical benchmark. Explicit dictionary aliases are more predictable than model guesses.
- The model can treat dictated instructions as a request to answer rather than text to proofread. Literal control-token isolation and content guards reduce this risk but do not prove semantic equivalence. Small prompt changes can affect this behavior.
- The historical Python benchmark does not establish native-helper latency. Verified-file loading, tokenization, initial Metal kernel work, input length, and available hardware all affect responsiveness.

## Command line and checks

To install an already-downloaded pinned MLX snapshot without a network transfer:

```sh
build/Sotto.app/Contents/MacOS/Sotto --import-text-model /path/to/pinned/model-directory
```

Import copies the six expected files into private staging, verifies the complete manifest, then atomically installs the model directory. Source Hugging Face cache symlinks may be resolved while copying; the installed directory contains regular files. An invalid/incomplete import never replaces the current model. This command does not alter config, history, or the legacy GGUF.

The text-only command reads a UTF-8 text file and prints a processing record as JSON. It reads an existing config snapshot without writing, migrating, or watching it; omitting `--config` selects the normal `~/.murmur/config.json`.

```sh
build/Sotto.app/Contents/MacOS/Sotto --correct-text /path/to/transcript.txt \
  --config "$HOME/.murmur/config.json"
```

For audio, explicit `--config` enables the configured dictionary/proofreading pipeline. Without `--config`, file transcription retains the baseline Whisper/cleanup/list behavior for compatibility. No command implicitly downloads weights, opens a microphone, or installs a hotkey.

```sh
build/Sotto.app/Contents/MacOS/Sotto --transcribe /path/to/mono-16khz.wav \
  --json --config "$HOME/.murmur/config.json"
# Optional archival only when explicitly requested:
build/Sotto.app/Contents/MacOS/Sotto --transcribe /path/to/mono-16khz.wav \
  --json --config "$HOME/.murmur/config.json" --archive-root /path/to/archive
```

File transcription writes no history without `--archive-root`. Text-only correction does not create audio history.

```sh
./scripts/test-corrections.sh
python3 scripts/test-text-engine.py \
  --helper .build/text-native/sotto-text-engine \
  --model "$HOME/.murmur/models/Qwen3-4B-Instruct-2507-MLX-4bit"
```

The packaged script checks text-only cases and synthesized audio through the configured speech/dictionary/proofread/archive path. The Python harness checks native helper protocol/recovery and synthetic proofreading cases. These are tests, not app runtime dependencies or live microphone/paste checks.
