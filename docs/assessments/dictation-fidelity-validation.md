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
