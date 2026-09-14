# Follow-up: Missing negations in speech recognition

Deferred by Ben on September 13, 2026. Separate from the current dictation-fidelity implementation; no extra audio pass or associated diagnostics are being shipped in that change.

Whisper is already using beam search 5, temperature 0, and no temperature fallback. A repeated identical decode is not independent verification. A text-only model cannot distinguish “merge this” from audio that actually said “never merge this.” Token confidence also cannot certify absence: an omitted word has no token confidence, and a wrong transcript can be confident.

1. Add bounded server-side ASR diagnostics alongside existing audio: decode settings, effective hints, segment times/text, selected-token confidence summaries, and filtered segments with reasons. Reuse the vendored public API. Do not turn diagnostic collection into a second inference pass or change filtering by default; measure its overhead.
2. Assemble human-recorded positive/negative pairs: “merge / never merge,” “can / can't,” “have / haven't,” plus quiet negatives, pauses, short answers, and realistic microphones. Use the existing synthetic probes as supplementary coverage. Human recordings are a required input before claiming real accuracy gains.
3. Compare baseline Whisper with alternate decode settings and padded audio crops offline. Keep whole-recording comparisons in the experiment because a confidence-only trigger can miss confidently wrong outputs. Measure negative omissions, invented negatives, total answer recall, and p50/p95 recognition and release-to-result latency on this Mac.
4. Select any proposed mode only if it measurably improves omission recall without unacceptable invented negatives, content loss, or latency. Do not ship a verification toggle or silently change model/runtime as part of the initial fixes.
5. If results justify a later mode, bring back measured tradeoffs and a concrete disagreement policy for review. Do not automatically choose whichever transcript contains a negation. A reviewable uncertain span is a possible follow-up, not part of this plan's default insertion flow.

No configuration can guarantee every missing negative is caught. This experiment establishes whether an additional audio pass helps enough to be useful.

