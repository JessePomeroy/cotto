# Dictation fidelity validation

Verified September 13, 2026 for implementation commit `9030c36` on `codex/dictation-fidelity`. [Missing-negation audio rechecking](../follow-ups/missing-negation-recognition.md) remains a separate follow-up.

- Mac: **230 tests passed** across client/native UI, server, portable domain, and core targets.
- Linux ARM64: **86 portable server/domain tests passed** under Swift 6.2.4. Both changed C++ helpers passed Linux Clang syntax/type checks. No Linux model inference or CUDA execution was performed.
- Both real Qwen helpers passed protocol/model smoke tests on this Mac: Mac MLX and the llama.cpp GGUF helper. Checks include explicit color/number/negation repairs, genuine alternatives and numeric contrasts, intentional “like,” repeated wording, custom prompts, role-token contents, context bounds, and process lifecycle.
- The real Whisper helper passed whole-term vocabulary-budget tests, large Unicode requests, priority retention, speech/silence, and lifecycle checks. This proves effective hint inclusion; synthetic homophone tests still do not establish a recognition accuracy improvement.
- The signed server package and Sotto Dev app contain the same tested default prompt (1,253 UTF-8 bytes; SHA-256 `64a5a941c3b45cbe0a4fc3efde479beae1248b5fadd635064581987b3270ebb4`).

## Running server checks

Two public 11-second JFK audio fixtures completed through Whisper, Qwen, and the HTTP event stream in **0.487 and 0.445 seconds after upload finish**. Original-audio retention on/off, exact archived audio bytes, transcript artifacts, device identity, and delivery receipts passed. These are local fixture timings, not a network or human accuracy benchmark.

Seven further synthetic audio generations exercised the complete running Dev server:

| Fixture | Observed result |
| --- | --- |
| “Twenty four” | `24` preserved |
| List beginning at 5 | Items 5, 6, 7, 8 retained and formatted |
| “Auth middleware” | Whisper produced `off middleware`; an explicit scoped phrase alias produced `auth middleware` |
| “Turn off the lights” | Legitimate `off` preserved with that same dictionary |
| Intentional “like” | Preserved by the default prompt |
| Pause-separated short answers | Both `A` and both `Agreed` responses preserved |
| Custom shared prompt removing discourse “like” | Changed cleanup behavior successfully; other wording remained |

These cases completed in **0.216–0.420 seconds after upload finish**. Test generations were removed and the original shared preferences restored. The custom dictionary used by the scoped-alias check was also restored; no broad homophone substitution was installed.

The native Dev app was opened and visually inspected: server online, both models ready, shared fixed-height cleanup editor, reset action, and distinct Dev identity. Countdown tests verify the 150/179-second boundaries, automatic-stop notice, reset behavior, and unchanged layout footprint. Live microphone behavior remains available for Ben's testing.

Detailed local logs and fixture outputs are in the ignored `.local/fidelity/` directory; the aggregate Mac log is `.local/fidelity-tests-final.log`. The independent Dev runner is available at `http://localhost:8391`; `scripts/run-dev.sh status` checks it.

## PR review validation

After incorporating the parent PR's endpoint, Dev runner, and decoded-list fixes, the combined branch passed **240 Mac tests** and **90 Linux ARM64 tests**, plus the isolated Dev runner process/port checks. Duplicate vocabulary now fails request validation before helper execution. Four apology examples that previously allowed lost wording, numbers, or negations now reject those proposals; clear quantity and negation corrections still pass. The historical assessment JSON remains explicitly labeled as a pre-fix baseline.

The large prefixed list-number finding was a false positive: `Item 2026, apples.` and `Number 2026, apples.` produce item 2026, while ordinary `2026. Revenue increased.` remains prose. The benchmark imports `sys`, and both helper harnesses expose `--server` through their shared argument function; all three `--help` commands passed. Review logs are in `.local/pr-review/`.

The final review pass added Unicode/work bounds and wider alignment scores, plus removal of the HUD's hidden 30-point native window area. **244 Mac tests** and **93 Linux ARM64 tests** pass. The overflow fixture fits the existing 6,000-character and 24 KiB inference limits but produces 6,000 alignment tokens; it now safely rejects cleanup. A 5,850-character ordinary dictation remains accepted. Native WindowServer probes confirm the removed hidden HUD area resolves to the underlying window while the capsule stays fixed; this checks hit selection, not a delivered button click.

A subsequent cue-search check bounds repair and hesitation comparisons before scanning ambiguous repeated cues. The 500-cue fixture falls back safely, ordinary multiple repairs still work, and anchored single-word sorry replacements pass alongside the preserved-apology and standalone-answer regressions. **246 Mac tests** and **95 Linux ARM64 tests** pass with these final changes.

Answer-boundary checks also cover adjacent short corrections and preserve standalone answers before er/err/erm hesitations. With these checks, **248 Mac tests** and **97 Linux ARM64 tests** pass.

The storage and compound-word review fixes pass **258 Mac tests** and **107 Linux ARM64 tests**. Hyphenated cue words remain protected, while spaced dashes still allow spoken corrections. Rejected proposals have a Unicode code-unit bound; excessive dictionary expansion keeps the entire original text. Preferences and generation writes enforce their restart read limits before replacing stored state. The oversized-generation fixture retains its audio and restarts successfully. The shared storage fixes also pass **223 Mac tests** on the base PR independently.

Final input validation brings the totals to **259 Mac tests** and **108 Linux ARM64 tests**. Shared settings reject individual preferred terms above Whisper's 16 KiB input limit, and direct inference calls reject surrounding whitespace before invoking the helper. The role-marker protocol fixture uses its own 173-byte prompt, independent of a maximum-size custom cleanup prompt; the real MLX helper returned the expected sentence in 0.102 seconds.
