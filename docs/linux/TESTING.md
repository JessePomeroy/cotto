# Testing

The supported entry points are `Linux/src/main.cpp` and `Server/src/main.ts`.
Tests for inactive receiver prototypes do not certify those production paths.
First-party tests and CI run on Linux; no Swift/macOS gate is part of this fork.

## Local gates

Build the native client first; gates do not build automatically:

```zsh
bun install --frozen-lockfile
cmake -S Linux -B build/linux -G Ninja
cmake --build build/linux
scripts/run_test_gates.sh fast
scripts/run_test_gates.sh subsystem desktop
scripts/run_test_gates.sh subsystem pi
scripts/run_test_gates.sh subsystem server
scripts/run_test_gates.sh broad
```

| Gate | Scope |
| --- | --- |
| `fast` | Five entries: native settings UI, personal dictionary, PCM core, generation protocol, Pi integration. |
| `subsystem desktop` | Startup profile configuration, UI, tray, clipboard paste, KDE shortcuts; private D-Bus where needed. |
| `subsystem pi` | Native bridge, Pi integration, recording-status publisher. |
| `subsystem server` | Bun server tests, fake inference helpers, temporary archives, and isolated HTTP. |
| `broad` | Server tests and every native CTest entry. |

Selections use `--no-tests=error`. CMake reports when Bun is missing; install the
pinned Bun version rather than treating missing Pi coverage as success. The gate
script can use an existing local Bun tool copy, but does not download one.

The suite currently has 188 server tests and 12 CTest entries. Fast takes
roughly five seconds; the broad native portion takes roughly 30 seconds. Timings
are illustrative, not thresholds. The optional acoustic test normally **skips**
without explicit inputs; a passing CTest entry does not prove live inference.

Additional developer checks:

```zsh
bun run fmt:check
bun run check
bun run generate:api --check
node Linux/tests/CheckPiTypes.mjs /absolute/path/to/pi-coding-agent
bun Linux/tests/PiVoiceProbe.mjs /absolute/path/to/pi-coding-agent build/linux/sotto-pi-bridge-tests
```

The installed-Pi probe exercises the actual editor adapter using an isolated Qt
fixture and temporary preference/runtime directories. It does not load an
extension into a live user session, request microphone capture, or submit text.

## Coverage that matters

- QML mouse/keyboard navigation, draft preservation, default/minimum window sizes,
  recovery/Copy, recording controls, close/hide, and cancellation before Quit.
- Microphone sample/channel handling and streaming conversion boundaries.
- Admission before capture; bounded uploads, sequence acknowledgements, exact
  finish counts, disconnect/cancel handling, and stale-result rejection.
- Private dictionary persistence, validation, empty overrides, frozen per-take
  hints, recognition/correction integration, and unchanged shared preferences.
- Pi one-use IDs across 4,101 takes, replay rejection, ownership, malformed frames,
  deadlines, receipts, draft/cursor protection, and recording observation.
- Clipboard ownership changes and one-attempt dispatch; shortcut/session signals;
  tray Open/Quit separation and read-only desktop activation; generated startup
  units honor XDG configuration and explicit profile overrides.
- Server archive locking, HTTP policy, model verification, helper cancellation/
  replacement, deterministic text rules, and isolated compiled-server smoke tests.

The long-session Pi regression adds roughly nine seconds to the broad suite and
is deliberately outside the fast gate. It tests the former lifetime exhaustion
bug rather than an implementation-detail cache size.

## CI

Linux checks run server formatting/types/tests/API freshness, a native Qt desktop
build/test job in Arch Linux, compiled coordinators on Linux x64/arm64, and CPU
helper package builds on both architectures. Release-package jobs are explicit
or tag-triggered and Linux-only; merging a PR is not a release or deployment.

Native test buses disable D-Bus service activation, and GUI fixtures use offscreen
software rendering. They do not manipulate the real desktop or launch its services.
Default tests must not call paid/credentialed providers, load real model weights,
or silently depend on a developer's running server.

## Explicit acceptance, not default tests

Real microphone/model tests, GPU benchmarks, physical shortcuts, permission dialogs,
lock/suspend, device unplug/reconnect, destination changes, and fresh-login startup
require explicit setup and user participation. Helper/acoustic scripts may use
public fixtures or a configured live server; inspect their options first and use
isolated data. They are never automatic evidence of correct desktop insertion.

See [current status](STATUS.md) for outstanding acceptance and
[architecture](../architecture.md) for the safety boundaries under test.
