# Configuration

Device preferences belong to each Mac. Processing preferences and history belong to the selected server and are shared by every connected client.

## This Mac

The normal Dev client directory is `~/Library/Application Support/Sotto Dev`. `SOTTO_CLIENT_DATA_DIR` selects a different directory for an isolated run; `scripts/run-dev.sh` defaults it to `.local/client` and selects the local server endpoint for its configured port.

| Location | Contents |
| --- | --- |
| `config.json` | Hold key, launch-at-login preference, microphone selection and named priority lists. |
| `client.json` | Server endpoint, stable device ID, and display name. |
| macOS Keychain | Bearer credential scoped to the exact endpoint and client data directory. |
| Native app defaults / macOS | Window and appearance state, first-launch bookkeeping, privacy grants, login-item approval. |

`SOTTO_SERVER_URL` overrides the saved endpoint for a run. The default is `http://127.0.0.1:8391`. Use **This Mac** to set the server URL, token, and device name. URLs cannot contain embedded credentials, queries, or fragments. The HTTP client does not follow redirects with credentials.

Device config example:

```json
{
  "schemaVersion": 1,
  "holdKey": "rightOption",
  "launchAtLogin": false,
  "microphones": {
    "activeProfileID": "default",
    "profiles": [
      { "id": "default", "name": "Default", "priority": [] }
    ],
    "selection": { "mode": "automatic" }
  }
}
```

- `holdKey` is `rightOption`, `rightControl`, or `fn`. Right Option is the default.
- Microphone selection is `automatic`, `systemDefault`, or `fixed`. Automatic follows the active priority list, then available fallbacks. Fixed selection includes a stable device `uid`, `name`, and `transport`; populate these through **Microphone** rather than using transient Core Audio numeric IDs.
- The selected input remains pinned for the active take. Route preferences affect subsequent recordings.
- App edits save asynchronously and flush on normal quit. Valid manual `config.json` edits update the running app. Invalid JSON leaves the last good state active and is not overwritten; repair and save the file to recover.
- Device files use private directories/files and atomic writes. Unknown top-level config keys survive unrelated app edits. This is not collaborative editing of a local file.

JSON cannot grant microphone, Accessibility, or login-item approval. Sotto Dev has separate privacy grants from an installed Sotto app. Device preferences are created fresh; there is no legacy preference migration.

## Shared server preferences

Edit these under **Server preferences**, then choose **Save shared preferences**. The server persists a revisioned snapshot in `<data-dir>/preferences.json`. Concurrent stale saves return a conflict so one device does not silently overwrite another's changes. The server freezes a snapshot when it accepts each generation; edits affect future takes.

| Preference | Behavior |
| --- | --- |
| `language` | Recognition language; default `en`, with `auto` and the supported language choices in the UI. |
| `cleanText` | Light filler cleanup; default on. |
| `vocabulary` | Additional recognition hints, bounded to 16 KiB. |
| `dictionary` | Always-active named lists of preferred spellings and explicit aliases. |
| `textCorrectionEnabled` | Qwen proofreading; default on. Disabled/unavailable proofreading preserves deterministic dictionary/list processing. |
| `keepOriginalAudio` | Keep/upload microphone-format audio for future takes; default on. Normalized inference audio is always retained. |

Use the API/UI to update shared settings while the server runs; it does not watch the preferences file for external edits. The API sends `{ "revision": N, "preferences": { ... } }` and returns the next revision after validation.

All dictionary lists are active together. Default entries are **MiniMax** and **Codex**; deleting them or using an empty dictionary is respected. Preferred terms and aliases use whole-word/phrase matching, Unicode boundaries, and noncascading replacements. The dictionary supports up to 32 lists and 500 terms, with up to eight explicit aliases per term. Conflicting mappings are rejected. See [text correction](text-correction.md).

There is no history-disable or idle-unload setting in this version. The server owns generation history and keeps its models warm. The original-audio toggle does not delete old audio.

## Server process configuration

Bind address, port, token file, data directory, and model/helper paths are runner settings. They are configured on the server, separately from shared product preferences. See [server setup](../Server/README.md) for command arguments and environment variables.

- Same-machine: loopback HTTP, normally port 8391.
- Remote: the client accepts an explicitly configured HTTP or HTTPS endpoint. Use HTTPS for public hosting; plain HTTP can run over private Tailscale. Nonloopback server binding requires a token of at least 32 characters.
- Dev runner: `.local/server` for persistent server data, `.local/client` for device settings, `.local/server.log` for output, `.local/server.pid` for process tracking.
- Hosted runner: choose durable storage and supervise the independent process with launchd, systemd, or a container runtime.

The client does not own server lifetime, model installation, or shared files. Quitting the UI leaves the server available to other Macs.
