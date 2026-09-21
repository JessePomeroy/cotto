# Dictionary and cleanup

The server processes each complete take in this order: Whisper → mechanical cleanup → dictionary → list formatting → optional Qwen → dictionary → rewrite validation → composition. The Qt client receives a finished result for guarded delivery. Models and installation are covered in the [server guide](../Server/README.md#models).

## Dictionary and vocabulary

Edit the desktop's **Dictionary** screen and save one word or phrase per line.
These words belong to the user profile. Each generation freezes them at admission;
shared server preferences remain unchanged, and an empty personal list stays empty.

The server API also supports shared lists and explicit aliases for other clients.
Those are separate from the compact desktop's plain word editor:

- Preferred spellings normalize case. Explicit aliases replace whole words or phrases, such as `mini max → MiniMax`. Longer matches win, and replacements do not cascade.
- Use narrow aliases like `off middleware → auth middleware`; a broad `off → auth` also changes legitimate “turn off.”
- The API supports priority terms. Whisper fits whole terms into its token budget;
  generation metadata records included and omitted hints. Qwen has a separate
  bounded hint budget. Replacements still apply to terms omitted from model hints.
- **Recognition vocabulary** adds speech hints. Hints improve the odds of recognizing unusual names; they cannot reliably distinguish every homophone.
- Cotto's user-local dictionary starts empty; project names are not application
  defaults. No automatic learning from edits or history occurs. Omitted API
  overrides preserve the existing shared defaults for non-Qt clients.

## Cleanup instructions

The shared `proofreadingPrompt` API preference is the Qwen system prompt. Its default has four freely editable sections: Cleanup, Spoken corrections, Preserve, and Output. It keeps intentional “like,” repetition, answers, numbers, and negations, while allowing explicit spoken corrections. Examples distinguish “42, sorry, 24” from a contrast such as “42, not 24.” It also forbids translation and added information.

Update shared preferences with their current revision through the API; the compact
Qt interface does not yet provide this editor. Changes affect future takes.
Disabling `textCorrectionEnabled` keeps the deterministic dictionary/list result,
including fillers.

The prompt guides Qwen; it cannot bypass the validation rules below.

## Preservation checks

- List formatting preserves standalone numeric answers and spoken numbering, including resumed, skipped, repeated, or out-of-order numbers. Qwen cannot create or advance list continuation state.
- Cleanup rejects changed list markers, unsupported dictionary names, lost answers, changed quantities/negations, excessive wording changes, and model control tokens or response preambles.
- Explicit corrections can remove an abandoned phrase only when bounded alignment verifies the cue and replacement. Ambiguous apologies or clause restarts can fall back to the source. Unrelated wording remains protected.
- Near-spelling and supported split-name corrections can pass; more ambiguous names should use explicit aliases. This conservative matching prevents a dictionary hint from licensing an invented name.

Rejected, unavailable, or failed proofreading keeps the already-cleaned, dictionary-corrected, list-formatted source. History records raw text, the proposed/accepted cleanup, its outcome/reason, verified corrections, and model details. See [storage](architecture.md#storage).

The checks do not prove identical meaning. Whisper can omit words; Qwen can mishandle homophones or instructions. The proofreader receives the current dictated chunk, language, preferred terms, and cleanup prompt—not surrounding documents, clipboard contents, or screenshots.

## Limits and testing

The prompt limit is 4,096 UTF-8 bytes. Qwen input is capped at 6,000 characters; its context is 8,192 tokens with 2,048 reserved for output. Oversized text, vocabulary, or validation work skips/rejects cleanup instead of accepting truncated output. The [helper protocol](../TextEngine/README.md) lists lower-level bounds.

Run `bun run test` for provider-free dictionary/validation tests.
`SOTTO_TEXT_MODEL=/path/to/model.gguf scripts/test-corrections.sh` explicitly runs
the real packaged Qwen helper; it is not an automatic test gate. To test the
built-in prompt directly, pass `--server build/server/sotto-server` to the Linux
Python helper harness. An explicit `--prompt FILE` preserves the file's contents, including trailing newlines. A redirected CLI prompt export includes an extra delimiter newline; use `--server` to avoid accidentally testing different prompt bytes.

## Open question: omitted negations

Audio rechecking is deferred. A text-only cleanup model cannot recover a negation that Whisper never transcribed, and repeating the same decode is not independent verification.

Before adding a verification mode, benchmark human-recorded positive/negative pairs and difficult short answers. Compare baseline recognition with alternate settings and audio crops; measure omissions, invented negations, answer recall, and p50/p95 latency. Ship a mode only if the measured benefit justifies the added delay and false corrections. No current setting guarantees every omitted word is caught.
