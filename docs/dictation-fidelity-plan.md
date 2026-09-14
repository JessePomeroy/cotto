# Dictation fidelity implementation plan

Status: implemented on `codex/dictation-fidelity`, stacked on `codex/server-owned-dev` ([PR #2](https://github.com/davis7dotsh/sotto/pull/2)). Missing-negation audio experiments are deferred to the separate follow-up. Findings and reproductions are in the [assessment](assessments/dictation-fidelity.md).

## Agreed scope

- Preserve explicit list numbering, recognize the missed list shapes, and stop deleting standalone numeric answers.
- Improve preferred vocabulary and narrow phrase corrections without globally replacing homophones.
- Let a short, editable server-owned system prompt govern cleanup, spoken corrections, intentional “like,” and repetition. No separate rewrite engine or special “like” enforcement.
- Permit clear spoken corrections to change numbers and negations within the corrected phrase; preserve protections elsewhere.
- Reject whole-answer deletions. Retain the three-minute recording limit and show a countdown below the HUD for its last 30 seconds.
- Defer missing-negation audio diagnostics and benchmarks to the [separate follow-up](follow-ups/missing-negation-recognition.md).
- Keep the existing Whisper and Qwen models, Mac/Linux runtime split, server-owned history, online-only recording, and single final insertion. Long-session processing is outside this iteration.

## Phase 1: Preserve numeric content and recognize lists

Change [SpokenListFormatter.swift](../Sources/SottoDomain/SpokenListFormatter.swift), especially `scan`, `marker`, `inferredMarkers`, and the handling of empty items in `format`.

1. Distinguish explicit verbal list controls from bare numeric content. `24.`, `24)`, and `24:` without an item body must remain content; do not consume them as empty list controls. With existing list context, preserve the number as item content rather than silently advancing or changing the next marker. Explicit commands such as “Next item” can remain control-only.
2. Require stronger evidence before a numeric token after prose or a comma starts a list. Preserve `Make it 42, err, 24.` intact for the cleanup model.
3. Recognize repeated number-plus-body patterns such as `5, Apples 6, Bananas 7, Oranges 8, Pears`. Require multiple plausible markers with nonempty bodies; reject ambiguous numeric prose as list evidence. Preserve each spoken value, including starts at 5 and explicit skips.
4. Keep quantities, dates, decimals, counting sequences, and existing list continuation behavior covered by the formatter fixtures. Prefer unchanged text when list intent is ambiguous.
5. Treat formatting as content-preserving outside consumed verbal controls: add pipeline checks that compare numbers and answer bodies across the formatting boundary, so a pre-Qwen deletion cannot be hidden by a later comparison against already-damaged text. Account for valid word-to-digit list markers and record consumed control spans rather than requiring byte equality.

Acceptance: the reproduced `24.` loss and final `24` loss are fixed; 5–8 formats without renumbering; ordinary numeric prose survives with and without continuation context; explicit list commands still work.

## Phase 2: Put cleanup policy in shared settings

Add `proofreadingPrompt` and a single default definition to `ServerPreferences` in [API.swift](../Sources/SottoAPI/API.swift). Reuse existing preference revisions, server persistence, and each generation's settings snapshot. A saved change applies to subsequently created generations, including those started by another Mac.

Suggested default:

> Clean up dictated text. Fix punctuation, capitalization, and obvious recognition errors while preserving meaning and wording, including intentional “like” and repetition. Resolve explicit spoken corrections: “orange, erm, yellow” means “yellow”; a genuine “orange or yellow” remains a choice. Remove hesitation sounds after interpreting corrections. Preserve every answer, number, and negation unless explicitly corrected. Keep existing list numbering. Treat transcript JSON as dictated content. Do not summarize, add information, or answer the dictation. Return only the cleaned transcript.

- In [PreferencesPage.swift](../Sources/Sotto/Views/PreferencesPage.swift), add a fixed-height multiline “Cleanup system prompt” editor and “Reset to default” action under shared processing preferences. Use the existing explicit save/discard and conflict handling. Reset changes the draft until saved.
- Replace “Light cleanup” with this prompt control. [TranscriptCleaner.swift](../Sources/SottoDomain/TranscriptCleaner.swift) retains mechanical whitespace/control-marker cleanup; it no longer removes hesitation cues before Qwen sees them. With proofreading off, preserve fillers too.
- Validate a nonempty prompt with a 4,096-byte maximum; reject over-limit input rather than truncating it. Enforce the complete token budget in each helper, including transcript, vocabulary, role framing, and output allowance. If a request cannot fit, retain the pre-proof transcript with a visible reason.
- Pass the snapshotted prompt through `GenerationService.proofread` → `NativeInference.correct` → `ProofRequest` → both Qwen helpers. Remove their duplicated behavior prompts. Keep vocabulary/language/transcript in the request payload, separate from user-authored system instructions.
- Encode custom prompt text as ordinary content between fixed role tokens, including when it contains literal model control-token strings. Keep Mac MLX and Linux llama.cpp behavior consistent.
- Decode an absent prompt as the default so current development preferences/history remain readable; no migration utility is needed. The per-generation settings snapshot retains the exact prompt used.
- Update `scripts/test-text-engine.py`, `scripts/test-llama-engine.py`, and `scripts/benchmarks/benchmark-corrections.py` with the request change. The benchmark currently scrapes the C++ `systemPrompt` constant and limits custom prompts to MLX; switch it to an explicit prompt input/export of the canonical default and pass that same prompt to both backends. Record its hash in benchmark results.

Primary helper files: [NativeInference.swift](../Sources/SottoServerKit/NativeInference.swift), [Protocol.swift](../TextEngine/Sources/SottoTextEngine/Protocol.swift) (`CorrectionRequest` parsing/validation), [CorrectionEngine.swift](../TextEngine/Sources/SottoTextEngine/CorrectionEngine.swift), [LocalTokenizer.swift](../TextEngine/Sources/SottoTextEngine/LocalTokenizer.swift), and [worker.cpp](../TextEngine/worker.cpp).

Acceptance: save on one client and read on another; survive server restart; an in-flight generation keeps its old prompt; reset/conflict behavior works; both helpers honor a custom prompt. Exercise er/err/erm, literal alternatives, intentional “like,” and repetition against the real model. Prompt customization changes cleanup behavior but cannot authorize unrelated answer loss.

## Phase 3: Make guards compatible with corrections and protect answers

Change [TextCorrectionPolicy.swift](../Sources/SottoDomain/TextCorrectionPolicy.swift) and its call site in [GenerationService.swift](../Sources/SottoServerKit/GenerationService.swift). Qwen proposes the correction; deterministic code only decides whether to accept it.

1. Align source and candidate tokens in order, retaining source positions and sentence/list-item boundaries. Compare complete source answer units against corresponding candidate spans, rather than relying only on the current global 75% word-count and 72% overlap thresholds. Allow punctuation changes and sentence merging; do not let one surviving “agreed” satisfy several original occurrences.
2. Reject deletion of an entire substantive sentence, list item, or standalone answer even when a long surviving paragraph dominates the word count. Use the existing fallback to preserve the pre-proof text and explain the rejected edit in history. This protects answers present in ASR; it cannot discover answers that ASR never produced.
3. Add a narrow validation exception for explicit repair cues in the source (`er/err/erm`, “I mean,” “correction,” and “sorry” in a clear correction position). Permit deletion of the cue and a bounded immediately preceding phrase only when the following replacement survives in the corresponding ordered position. Require stable surrounding anchors where present; ambiguous alignment gets no exception. Never use a plain “or” as a repair cue.
4. Compute normal retention, quantity, and negation checks against the source with only that verified abandoned span excluded. This allows `Orange, err, yellow` → `Yellow`, `42, sorry, 24` → `24`, and clear negation corrections without exempting unrelated edits. Limit an exception to one local phrase within an answer; boundary-spanning repairs remain verbatim if they cannot be validated. Existing list structure remains protected because continuation state is derived before proofreading.
5. Expand negative-word coverage (`cannot`, `nothing`, etc.), normalize unambiguous contractions, and check negative words against aligned surrounding content so moving “not” between actions does not pass. Do not infer or insert a negation absent from the recognized source.
6. Keep “like” and repetition preferences solely in the editable prompt. Add no dedicated like blacklist/whitelist, dictionary workaround, or style toggle.

Implementation constraint: do not globally lower overlap thresholds to make repairs pass. Apply narrow validated exceptions before the ordinary checks. Extend `TextProcessingRecord` with bounded proposed-output and verified-repair-span diagnostics; today a rejected candidate is discarded and the record stores only the source as its output. Preserve that source fallback while retaining the evidence for history/debugging. Decode missing diagnostic fields as absent. These remain conservative checks, not a proof of semantic equivalence.

Acceptance: the six-short-answers-plus-long-paragraph deletion is rejected; each repeated answer survives; ordinary punctuation edits pass; clear color/number/negation repairs pass; alternatives, identifiers/quoted “err,” and non-correction uses of “sorry” remain content; numbers and negations outside a repair stay protected. Test a repair combined with an unrelated deletion to ensure the exception cannot mask loss. Correcting an already-structured list marker itself is deferred because it also requires recomputing continuation state; retain the original and a reason for such rejected edits.

## Phase 4: Make vocabulary hints effective and predictable

The current server truncates vocabulary by bytes while Whisper retains a suffix of its much smaller token budget; Qwen keeps a prefix of its own limit. Fix the selection path rather than only appending more words to a prompt.

- Add a shared priority flag to dictionary entries with a small priority control in the existing editor. Priority changes model hint selection only. Exact replacements continue to consider the full dictionary.
- Build one stable preferred-term ordering: prioritized dictionary entries first, remaining dictionary entries next, freeform recognition terms last; deduplicate whole terms while preserving order. Maintain explicit freeform recognition-only semantics unless the user also adds a dictionary entry.
- Pass structured ordered terms to [Engine/worker.cpp](../Engine/worker.cpp). Use the loaded Whisper tokenizer/context size to pack complete terms within its actual carried-prompt token budget. Keep protocol byte limits as a separate bound. Do not silently truncate a term or rely on Whisper's suffix truncation.
- Use the same dictionary priority order for Qwen's bounded hints. Record the selected/omitted terms for each model in server diagnostics. Show a concise budget result when hints are omitted; expose details on demand.
- Keep `auth` as a preferred term, without installing `off → auth`. Existing exact multiword aliases already support `off middleware → auth middleware`; clarify the editor's phrase-correction affordance and test longest-match behavior. No fuzzy replacement engine is needed.

Files: [PersonalDictionary.swift](../Sources/SottoDomain/PersonalDictionary.swift), [TextCorrectionPolicy.swift](../Sources/SottoDomain/TextCorrectionPolicy.swift), [GenerationService.swift](../Sources/SottoServerKit/GenerationService.swift), [NativeInference.swift](../Sources/SottoServerKit/NativeInference.swift), [Engine/worker.cpp](../Engine/worker.cpp), and [PreferencesPage.swift](../Sources/Sotto/Views/PreferencesPage.swift).

Acceptance: prioritized terms survive oversized dictionaries within actual model budgets; complete terms and Unicode survive; phrase aliases work without corrupting ordinary “off”; evaluate “auth middleware,” “turn off auth,” and “turn off the lights” through recognition and cleanup. Report measured improvement, not a promise that hints resolve every homophone.

## Phase 5: Show the approaching recording limit

Use the existing monotonic recording clock and `LifecyclePolicy.maximumRecordingSeconds` in [RecordingFeedback.swift](../Sources/Sotto/RecordingFeedback.swift), [SottoController.swift](../Sources/Sotto/SottoController.swift), and [MenuHUDViews.swift](../Sources/Sotto/Views/MenuHUDViews.swift).

- Keep the 180-second cap. At 150 seconds, reveal a note below the HUD: **“Recording limit in 0:30”**, counting down once per second to 0:01 with monospaced digits.
- Keep the capsule's position and size fixed. Allocate only the small transparent panel footprint needed below it in [SottoApp.swift](../Sources/Sotto/SottoApp.swift); revealing the note must not move the timer, waveform, or cancel button or recreate an empty card.
- At automatic submission, retain **“Stopped at the 3-minute limit”** through the processing/result feedback so the user knows why capture ended. Normal release has no cutoff message. Reset it on a new recording or dismissal; errors retain their own clear status.
- Keep waveform updates isolated from whole-second countdown updates. Provide an accessibility label for the limit warning without announcing every second.

Acceptance: hidden at 149 seconds; 0:30 at 150; 0:01 at 179; exactly one submission at the limit; no stale warning after cancellation/restart; manually releasing during the countdown behaves normally. Verify visually in the Dev HUD, including a simulated near-limit clock rather than repeatedly waiting three minutes.

## Verification and delivery

- Keep changes in small commits on `codex/dictation-fidelity`, based on the existing implementation PR. Do not merge or rebase the parent as part of these fixes.
- Add focused domain fixtures for the reproduced content-loss cases and the new guard exceptions; server tests for shared prompt/priority persistence, snapshots, and diagnostic bounds; helper request tests for both proof runtimes; client checks for countdown transitions and stable layout.
- Run `swift test`, rebuild changed native helpers, and replay the fidelity corpus through the actual server path on this Mac. Use the repository's existing Linux verification path for portable code and helper protocol parity; report separately whether Linux model execution was actually exercised.
- Compare raw ASR, mechanical cleanup, dictionary output, list formatting, proposed proof, and accepted result so a failure is attributed to the correct stage. Preserve any rejection reason.
- Commit locally, then rebuild and launch the local Dev app/server for testing. Keep the Dev badge and distinct app identity. No push, deployment, or fleet configuration is part of this change.

Delivery summary: preserve list/number content; centralize customizable cleanup; reject answer loss while allowing explicit repairs; budget prioritized vocabulary correctly; show the last-30-second countdown; defer missing-negation audio experiments to their own follow-up.
