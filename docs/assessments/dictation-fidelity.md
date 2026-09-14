# Dictation fidelity assessment

Assessed September 13, 2026 at `6834298`, the head of [PR #2](https://github.com/davis7dotsh/sotto/pull/2). The assessment lives on `codex/dictation-fidelity`, based directly on `codex/server-owned-dev`; its future PR base is configured to that parent branch. This assessment changes no product behavior.

Six agents reviewed the six complaints independently. We ran isolated probes against the actual Swift domain functions, 25 cases through the packaged Qwen MLX helper, and 17 speech-recognition cases through the packaged Whisper helper, followed by the real formatting and proofreading policy. Speech fixtures used macOS Samantha TTS, including silence-separated short answers. These are concrete reproductions and controls, not a human word-error-rate benchmark. We do not have the friend's original audio, so we cannot claim to reproduce his exact delivery or accents. Linux llama.cpp uses the same prompt and policy, but its model outputs were not exercised in this assessment.

Machine-readable stage-by-stage results: [dictation-fidelity-results.json](dictation-fidelity-results.json). Local probe programs remain in `.local/fidelity/`.

## Verdicts

| Complaint | Current verdict |
| --- | --- |
| 1. List starts/resumes at 5 but becomes 1 | **Handled for recognized list numbering.** Formatting recognition has gaps; numbers are not intentionally reset. |
| 2. “auth” becomes “off” | **Not reliably handled.** Reproduced with real Whisper; dictionary hints helped one case but not another. |
| 3. “orange, err, yellow” means yellow | **Not handled reliably.** No explicit repair interpretation; the model left both colors in our cases. |
| 4. Important negations disappear | **Partly handled.** Exact `never`, `not`, `haven't` are protected after recognition; other negatives and relocation have holes. |
| 5. Intentional “like” disappears | **Preserved in tested cases, incompletely enforced.** Cleanup keeps it and Qwen preserved our examples, but the rewrite policy allows removal. |
| 6. Short answers or large sections vanish | **Not handled end to end.** Three-minute cutoff, permissive deletion checks, and a reproduced numeric-answer deletion are material gaps. |

## 1. Preserve explicit list numbers

The actual formatter turns `Five, apples. Six, bananas. Seven, oranges. Eight, pears.` into items **5, 6, 7, 8**. This holds with no earlier take, and when continuation expected a different next number. Every recognized marker sets the spoken value; Qwen must preserve ordered markers and numbers or its proposal is rejected.

The real model kept the correctly formatted 5–8 list unchanged. A speech fixture produced `5, Apples 6, Bananas 7, Oranges 8, Pears`. The deterministic formatter missed that shape. Qwen proposed a correctly formatted 5–8 list, but the guard rejected it because the original had no list markers. The final retained all numbers as prose. That is a formatting gap, not the friend's reset-to-1 failure.

A standalone `Five, apples.` also remains prose without context; `Number five, apples.` explicitly starts item 5. Active list context can over-format subsequent ordinary prose until an end-list command is given.

**Fix:** keep number preservation; add narrowly defined recognition for strong repeated-number series and explicit list intent. Do not loosen the numbering guard globally or guess every number is a list. Pair missing-punctuation cases with ordinary numeric prose and explicit resumes.

Evidence: [SpokenListFormatter.swift](../../Sources/SottoDomain/SpokenListFormatter.swift#L85), [TextCorrectionPolicy.swift](../../Sources/SottoDomain/TextCorrectionPolicy.swift#L30), [GenerationService.swift](../../Sources/SottoServerKit/GenerationService.swift#L363).

## 2. Recognize uncommon homophones

Real speech results:

- `We need to fix auth middleware.` became `we need to fix off middleware`, both with default hints and with `auth, authentication, authorization, middleware`. Qwen left the error intact.
- `Turn off auth for the local test.` became `Turn off off for the local test` without hints. Qwen removed the apparent repetition, producing `Turn off for the local test`.
- Adding auth hints fixed that second speech example. The legitimate `Turn off the lights...` controls remained correct.

The default dictionary contains MiniMax and Codex, not auth. Adding auth as a term biases recognition and proofreading and protects correctly recognized occurrences; it cannot force acoustic disambiguation. A blanket `off → auth` alias is unsafe: actual deterministic probes changed `Turn off the lights` into `Turn auth the lights`. All dictionary lists are active, and replacements happen before the guard protects the resulting preferred term.

The valid dictionary can contain 500 entries, while Qwen receives at most 80 terms/4,096 bytes. Whisper also has a smaller token-context budget than the server's 8,192-byte prompt cap. A large valid dictionary does not mean every term is used as a model hint.

**Fix:** use preferred terms without broad homophone aliases; allow deliberate vocabulary priority and report which hints fit. Offer narrow, explicit phrase corrections such as `off middleware → auth middleware`. Evaluate audio-backed second-pass recognition for unresolved terms before attempting automatic contextual substitutions. Score both missed auth and corrupted legitimate off.

Evidence: [PersonalDictionary.swift](../../Sources/SottoDomain/PersonalDictionary.swift#L79), [GenerationService.swift](../../Sources/SottoServerKit/GenerationService.swift#L353), [TextCorrectionPolicy.swift](../../Sources/SottoDomain/TextCorrectionPolicy.swift#L8).

## 3. Interpret spoken corrections

Sotto has no explicit self-repair stage. Qwen kept `orange, err, yellow` and `orange, er, yellow` unchanged. Default cleanup removes `erm`, so that variation became `orange, yellow` before the model saw it. Our synthetic spoken err was recognized as `air`; this tests that particular synthesized sound, not the friend's human hesitation. It also remained unresolved.

The guard accepts both an intended `...yellow` proposal and an incorrect `...orange or yellow` proposal for the longer sentence. It can also accept deleting one side of a genuine `orange or yellow` choice. Conversely, a short `Orange, err, yellow → Yellow` repair fails the generic deletion threshold, and number/negation repairs can fail the protections designed to prevent meaning changes.

**Fix:** preserve repair cues until interpreted. Add a bounded repair step for clear markers such as “I mean” or “correction,” then extend to er/err with audio-backed examples. Record the abandoned and replacement spans; allow only that localized edit before applying normal proof safeguards. Do not globally weaken number/negation checks. If recognition already says `or`, text alone cannot determine whether it was a choice or a repair; do not rewrite every “or” as a correction.

Evidence: [TranscriptCleaner.swift](../../Sources/SottoDomain/TranscriptCleaner.swift#L11), [MLX prompt](../../TextEngine/Sources/SottoTextEngine/LocalTokenizer.swift#L158), [llama.cpp prompt](../../TextEngine/worker.cpp#L102), [TextCorrectionPolicy.swift](../../Sources/SottoDomain/TextCorrectionPolicy.swift#L45).

## 4. Preserve important negatives

The actual guard rejects removal of `never`, `not`, `haven't`, and curly-apostrophe `haven’t`; the server retains the pre-proof transcript. These words also survived both our synthetic audio and direct Qwen examples.

Confirmed policy gaps, using deliberately proposed harmful rewrites rather than claiming Qwen produced them:

- `cannot → can` and `nothing → something` are accepted.
- Moving `not` from one action/clause to another is accepted when the global negation-token sequence stays the same.
- Equivalent `haven't ↔ have not` is unnecessarily rejected.
- If Whisper never includes `never`, proofreading's comparison cannot detect its absence from the audio.

**Fix:** normalize unambiguous contraction forms, cover additional negatives, and check negation position relative to aligned surrounding words. Preserve the original on uncertain edits. Add real-speech minimal pairs with quiet negatives and pauses. Never insert a guessed missing negation without evidence from the audio. Surface rejected edits and their reasons in history so users can distinguish recognition from proofreading errors.

Evidence: [TextCorrectionPolicy.swift](../../Sources/SottoDomain/TextCorrectionPolicy.swift#L58), [negation tokenizer](../../Sources/SottoDomain/TextCorrectionPolicy.swift#L94), [proof fallback](../../Sources/SottoServerKit/GenerationService.swift#L404).

## 5. Preserve intentional “like”

The cleaner explicitly preserves “like,” “you know,” and repetition; only um/uh/erm are removed with light cleanup enabled. Qwen preserved all five direct like examples, including literal and discourse uses. The synthetic speech example also preserved like through recognition and proofreading.

However, actual guard probes accept `This is, like, the whole point → This is the whole point` and even `I would like to keep... → I would keep...`. The global overlap thresholds permit those deletions. Turning **Light cleanup** off does not change Qwen's prompt or disable it. The prompt also permits removing “clearly accidental repetition,” an ambiguity that already caused an omission in the auth/off fixture.

**Fix:** default to preserving words and repetitions; require explicit authorization for stylistic deletions. Add deterministic protection for chosen discourse words/phrases and rejection tests for both literal and discourse uses. Adding `like` as a dictionary term without aliases already protects its occurrence count after recognition, but users should not need to build a dictionary to make ordinary speech survive. Disabling proofreading preserves like already present in Whisper output; neither setting recovers ASR omissions.

Evidence: [TranscriptCleaner.swift](../../Sources/SottoDomain/TranscriptCleaner.swift#L12), [proof prompt](../../TextEngine/Sources/SottoTextEngine/LocalTokenizer.swift#L165), [term and overlap guards](../../Sources/SottoDomain/TextCorrectionPolicy.swift#L38).

## 6. Preserve short answers and complete sessions

### A reproducible loss before proofreading

Synthetic speech saying **“Twenty four”** was correctly recognized by Whisper as **`24.`**. The list formatter then returned **empty text**, classifying the number as a bodyless list control. Qwen is skipped for empty text, so its number guard cannot help. `Make it 42, err, 24.` similarly became `Make it 42, err,`, then Qwen returned `Make it 42, err.`.

The parser treats a digit under 1,000 followed by a period, parenthesis, or colon as an explicit list marker, even without an item body. It consumes that marker, then emits nothing for the empty item. This is independently reproduced by two agents and the root's real speech pipeline.

**Immediate fix:** preserve bodyless bare numeric content unless list intent is established. Keep deliberate verbal controls such as “Number five” distinct. Require stronger evidence before a number after prose/comma creates a list. Check preservation against raw ASR across every transformation, not only against the already-processed input to Qwen.

### Duration and coverage

Sotto auto-submits at **180 seconds** and the writer ignores later frames. It switches the HUD to processing but has no distinct duration-limit outcome or clear persistent explanation. A ten-minute speech cannot currently be captured as one take. Raising a single constant is insufficient: receiving sessions expire after 300 seconds, the native helper caps WAV files at 32 MiB, and proofreading is limited to 6,000 characters.

**Fix:** make the cutoff explicit immediately with a countdown and “Stopped at the three-minute limit.” To support longer sessions, retain one durable generation while recognizing bounded overlapping audio windows with timestamps and verified assembly. Coordinate all upload, size, duration, timeout, and proofreading limits.

### Short answers and deletion checks

The actual synthetic `A`, `Agreed`, and a sequence of both separated by two-second pauses survived recognition and proofreading. The direct Qwen fixture containing six short responses followed by a long answer also preserved those responses. We did not observe the friend's wholesale short-answer omission in these cases.

The defenses are still incomplete. A deliberately proposed rewrite deleting all six short responses but retaining the long answer passes the current 75% word-count/72% overlap checks. Short recordings also encounter the 250-ms admission cutoff, amplitude/RMS gate, Silero's 120-ms speech requirement, and suppression of Whisper segments above 0.6 no-speech probability. Those are potential omission paths, not measured failures for every short answer. Silero does not splice silence out of a speech-positive recording, which helps retain word boundaries.

**Fix:** reject whole-answer or sentence deletion rather than relying only on global word ratios. Add human-recorded sparse-answer and long-pause coverage tests, including numbers and quiet negatives. Record capture timeline gaps and ASR segment/filter decisions so missing content can be localized. Tune hallucination suppression against these fixtures rather than disabling it blindly.

Transport is comparatively strong: bounded queues fail explicitly, uploads carry per-stream sequence numbers and cumulative frame counts, and the server verifies exact finish counts and preserves sealed audio. These guarantees cover emitted PCM, not speech absent before the upload stream or removed by later transforms. Original audio and raw/final transcripts help investigation, but raw ASR already excludes suppressed Whisper segments.

Evidence: [numeric-marker classification](../../Sources/SottoDomain/SpokenListFormatter.swift#L312), [empty-item handling](../../Sources/SottoDomain/SpokenListFormatter.swift#L56), [duration timer](../../Sources/Sotto/SottoController.swift#L756), [capture cap](../../Sources/Sotto/System/AudioRecorder.swift#L458), [Whisper speech filtering](../../Engine/worker.cpp#L210), [upload validation](../../Sources/SottoServerKit/GenerationService.swift#L168), [history presentation](../../Sources/Sotto/Views/HistoryPage.swift#L146).

## Recommended order on the stacked branch

1. Fix deterministic content loss first: bodyless numeric answers, whole-answer deletion, broader/position-aware negation protection, and preservation of intentional words/repetition. Keep rejection/fallback visible.
2. Make the existing recording cutoff honest before increasing it. Then design bounded long-session processing with measurable coverage.
3. Add conservative explicit-repair handling without weakening protections elsewhere.
4. Improve prioritized vocabulary and scoped corrections; evaluate homophones with human audio before promising automatic recovery.
5. Keep a small permanent end-to-end fidelity corpus. Measure numbers, negatives, intentional words, and answer recall at each stage—not only aggregate word error rate or latency.

These are proposed fixes, not implemented changes. The running Dev app and server were not reconfigured by this assessment.
