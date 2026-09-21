# Pi-owned dictation

Pi-owned dictation returns text to the editor that explicitly requested the take.
It does not route to whichever application or terminal pane happens to be focused
when inference finishes, and it never falls back to global paste.

## Enable

Run the native client with `--pi-dictation` (the managed user service does this).
Install one Pi extension entry exporting the integration from your checkout:

```typescript
export { default } from "/absolute/path/to/cotto/Linux/integrations/pi/voice.ts";
```

Place that entry in your Pi extensions directory, then `/reload`. Do not install
multiple entries for the same integration. Pi's extension API is an external
integration boundary; use the strict typecheck and installed-editor probe when
upgrading it.

- **Ctrl+Shift+R:** start/stop Pi-owned recording.
- **`/cotto off` / `/cotto on`:** persistently disable/enable it.
- **`/cotto status`:** inspect readiness. `/sotto` remains a compatibility alias.
- **`○` / `●`:** idle/recording. Global Cotto recording can also fill the circle;
  it does not make that Pi pane the global destination.

Default-on readiness does not start capture. Compaction/navigation cancel the
current take without permanently removing readiness. Held-key repeats are latched
until the relevant release; elapsed time or completion does not fabricate a release.

## Editor boundary

The integration captures editor identity, revision, text, cursor, and session
ownership before connecting. It rechecks the snapshot, focus/modal state, idle
state, and adapter ownership before one synchronous insertion. Changed drafts,
custom editors, unavailable/RPC interfaces, and incompatible dialogs fail closed.
A cooperating question extension may expose an explicit answer-editor capability;
dictation never chooses an answer or submits the dialog.

No Enter or Submit action is sent. A callback failure after mutation is uncertain,
not permission to retry. Native receipts distinguish inserted, blocked, and
uncertain delivery. Actual OS focus across terminals remains outside this
editor-owned guarantee.

## Protocol v2

The socket defaults to `$XDG_RUNTIME_DIR/sotto-dictation/input.sock`. It requires a
private user-owned directory and socket; the bridge checks the peer UID. Same-user
processes remain trusted—this is not executable authentication. `--pi-socket` can
select another explicit private path. Without `--pi-dictation`, no bridge opens.

Pi opens one connection per take. The bridge sends a fresh server-generated UUID:

```json
{"v":2,"event":"hello","mode":"pi-owned","id":"<server-issued UUID>"}
```

The exact-field requests use only that ID:

```json
{"v":2,"id":"<server-issued UUID>","op":"start"}
{"v":2,"id":"<same UUID>","op":"stop"}
{"v":2,"id":"<same UUID>","op":"cancel"}
{"v":2,"id":"<same UUID>","op":"receipt","status":"inserted"}
```

The ID is consumed **before** capture is requested. Cancellation, rejection, and
receipt never make it reusable. Later connections get new IDs; old starts and
stale callbacks cannot match them. There is no growing replay set, eviction window,
or lifetime take limit. Version 1 clients are rejected before capture: update the
native client and `/reload` Pi together, without a legacy fallback.

Events are `recording`, `processing`, `cancelled`, `error` with a message, and
`transcript` with text. Every non-hello event carries the take ID. Receipt values
are `inserted`, `blocked`, or `uncertain`; a lost receipt is uncertain.

UTF-8 JSON frames are LF-delimited. Native request buffering is limited to 4 KiB;
Pi bounds incoming buffering to 256 KiB and insertion text to 64 KiB. Both sides
reject malformed/unexpected frames and control-character text. Native deadlines
are 15 seconds for start, four minutes for capture, two minutes for processing,
five seconds for receipt/partial requests, and five minutes for an unused connection.
Connection loss cancels only its owner and never transfers delivery to another take.

## Read-only global status

`$XDG_RUNTIME_DIR/cotto-status/recording.json` is independent of the socket protocol:

```json
{"v":1,"recording":true,"updatedAt":1780000000000}
```

It has one publisher, private ownership/mode checks, and an atomic one-second
heartbeat while recording. Pi polls with bounded reads and rejects symlinks,
public/oversized/malformed records, future timestamps, and records older than
2.5 seconds. Observation contains no transcript, device identity, or capture command.

## Verify

```zsh
scripts/run_test_gates.sh subsystem pi
node Linux/tests/CheckPiTypes.mjs /absolute/path/to/pi-coding-agent
bun Linux/tests/PiVoiceProbe.mjs /absolute/path/to/pi-coding-agent build/linux/sotto-pi-bridge-tests
```

The final probe uses the installed Pi editor API with an isolated native socket,
not a live user editor. It checks cursor insertion, draft guards, recording
observation, native receipts, and zero submissions. Physical terminal shortcut
transport is a separate acceptance check. See [architecture](../architecture.md).
