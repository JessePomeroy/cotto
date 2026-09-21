# Repository instructions

- This fork is Linux-only. The desktop is C++/Qt; the local server is Bun/TypeScript with native C++ inference helpers. Do not introduce Swift, macOS build paths, or unsupported-platform CI.
- Keep public documentation portable. Do not commit personal dictionary words, transcript evidence, absolute user paths, process IDs, local-session notes, or model files. Use ignored `.local/` storage for private validation artifacts.

- At the end of any turn that adds, edits, or deletes TypeScript files, run `bun run fmt` from the repository root after the final code edits and before committing or responding.

## Test suite policy

- Production authority: `Server/src/main.ts` starts the packaged local inference server; `Linux/src/main.cpp` starts the supported KDE/Wayland client. Tests for inactive receiver prototypes must not certify either path.
- Default Linux verification: `scripts/run_test_gates.sh fast` (about 5 s) after Linux edits. Then use `scripts/run_test_gates.sh subsystem <desktop|pi|server>` for the affected boundary. Run `scripts/run_test_gates.sh broad` (about 40 s) before a push or when requested.
- The server suite is provider-free and stays under `bun run test`; tests use local fixtures/helpers. An automatic test must not call a networked, paid, or credentialed provider.
- The archived receiver-prototype tests in `.local/testprune-archive/` are intentionally outside all gates. Do not add skip-forever or xfail-forever markers to hide failures; correct a test with production authority or remove/archive it instead.
- Record suite-shaping changes and measured gate timings in `docs/linux/TESTING.md`.
