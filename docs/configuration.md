# Configuration

Since 0.7.0, Sotto stores editable app preferences in **`~/.murmur/config.json`**. Version 0.8 adds dictionary lists and the optional local text-correction toggle to this same source of truth; it is not a periodic export.

- Editing a setting in Sotto updates this file automatically. Rapid edits are batched for roughly 150 ms, written off-main, and flushed on normal quit.
- Editing and saving the file updates the running app without a restart. The watcher handles both in-place saves and editor-style atomic replacements. There is no polling timer or config read on each hold-key press.
- An active dictation retains its shortcut/transcription settings, dictionary, text-correction toggle, and pinned input. Changes take effect for subsequent takes. History retention is also snapshotted per take.
- General → Settings file → **Show in Finder** reveals the file. The section shows save/configuration errors; the sidebar links to it when attention is needed.

## Example

```json
{
  "schemaVersion": 1,
  "holdKey": "rightOption",
  "language": "en",
  "idleMinutes": 5,
  "cleanText": true,
  "vocabulary": "",
  "textCorrectionEnabled": true,
  "dictionary": {
    "lists": [
      {
        "id": "personal",
        "name": "Personal",
        "entries": [
          { "id": "minimax", "term": "MiniMax", "aliases": [] },
          { "id": "codex", "term": "Codex", "aliases": [] }
        ]
      }
    ]
  },
  "launchAtLogin": false,
  "saveDictationHistory": true,
  "microphones": {
    "activeProfileID": "default",
    "profiles": [
      { "id": "default", "name": "Default", "priority": [] }
    ],
    "selection": { "mode": "automatic" }
  }
}
```

| Setting | Values |
| --- | --- |
| `holdKey` | `rightOption` (fresh-install default), `rightControl`, or `fn` |
| `language` | `auto`, `en`, `es`, `fr`, `de`, `it`, `pt`, `nl`, `ja`, `zh`, `ko`, `hi`, `ar`, `pl`, `ru`, `uk`, `sv` |
| `idleMinutes` | `0` after every take, `5`, `15`, or `-1` until quit; applies to both model helpers |
| `cleanText` | Boolean; light filler cleanup, separate from generative proofreading |
| `vocabulary` | Legacy string of comma-separated recognition hints; edited under Dictionary → Additional recognition hints |
| `dictionary` | Named lists containing preferred `term` spellings and explicit `aliases`; all lists are active |
| `textCorrectionEnabled` | Boolean, default `true`; use the optional local proofreading model when installed. Never triggers a download by itself |
| `launchAtLogin` | Desired login behavior; macOS still controls registration/approval |
| `saveDictationHistory` | Boolean; affects future takes only, never deletes history |
| `microphones` | Named priority profiles, active profile ID, and input-selection mode |

Microphone `selection.mode` is `automatic`, `systemDefault`, or `fixed`. Fixed selection includes a `device` object with `uid`, `name`, and `transport`. Priority lists use the same device objects, ordered most preferred first; disconnected devices keep their place. Use the Microphone page to populate accurate device UIDs, then edit the JSON if desired. IDs must be nonempty and unique within their respective lists; the active profile must exist. Do not substitute transient Core Audio numeric handles.

The file is strict JSON: no comments or trailing commas. Missing settings use defaults; explicit nulls, wrong types, unsupported values/schema versions, and malformed microphone/dictionary structures are rejected. Unknown top-level keys are preserved on app saves. Updating a microphone or dictionary preference writes its complete `microphones` or `dictionary` field, so use one editor at a time for simultaneous changes within that field.

## Dictionary and proofreading

- A missing `dictionary` key seeds the **Personal** list with **MiniMax** and **Codex**, without aliases. An explicit `"dictionary": { "lists": [] }` keeps an empty dictionary; deleting the initial terms does not cause them to reappear.
- Every list participates in correction. There is no selected/active-list flag: the Dictionary page's list picker only chooses which list you are editing.
- `term` is the preferred spelling. `aliases` are user-supplied whole-word or phrase corrections, applied case-insensitively; no substring guessing, fuzzy replacement, or automatic learning occurs. Preferred spellings themselves normalize capitalization. Aliases are not added to Whisper's recognition hints.
- Up to 32 lists and 500 terms are accepted. List names are nonempty single-line text up to 80 characters; terms and aliases are nonempty single-line text up to 128 characters. Each term can have up to eight aliases. IDs must be unique in their required scope, and a spelling cannot map to conflicting preferred terms across lists. Capitalization-only aliases are unnecessary and rejected.
- Preferred dictionary spellings supplement the legacy `vocabulary` hint string. The deterministic rules use the complete dictionary; the model receives a bounded subset of preferred terms to fit its context.
- `textCorrectionEnabled: false` disables only the second-model proofread. Dictionary replacements and deterministic list formatting remain active. The current take keeps its original toggle, even if JSON is changed mid-recording; an idle model unloads when correction is disabled.

The correction weights are separate from JSON at `~/.murmur/models/`. Download/removal and manual load/unload are under **Models → Text correction**. See [text correction](text-correction.md) for provenance, fallback behavior, and limitations.

## Migration and failures

Before 0.7.0, settings used macOS `UserDefaults` in the `dev.davis.murmur` domain, normally backed by **`~/Library/Preferences/dev.davis.murmur.plist`**. When config.json is absent at startup, Sotto seeds it with the existing shortcut, language, idle policy, cleanup, vocabulary, microphone preferences, history toggle, and current login registration. Existing valid JSON always wins over legacy preferences. The old plist is left untouched as a migration backup; user-facing settings no longer write to it.

Window placement and first-launch bookkeeping remain native macOS defaults. Microphone/Accessibility permissions and login-item approval remain macOS-owned; a JSON setting cannot grant permissions. A login registration failure keeps the requested preference in JSON and shows a warning on the login toggle instead of silently changing intent or retrying on unrelated edits.

Invalid or partially saved JSON leaves the last good in-memory configuration active and displays an error. App changes cannot overwrite the invalid file. Fix and save the file to recover automatically. On a fresh launch without any valid JSON, Sotto uses its legacy/default fallback until the file is repaired. Deleting the file while running does not recreate it or clear preferences; restore a valid file, or restart to seed a missing file again.

App writes merge only changed top-level settings into the latest valid disk contents, preserving unrelated edits. They use a private temporary file and atomic replacement, with bounded retries if a changed file is detected. This is not a collaborative editor: two editors changing the same setting simultaneously can still compete. Failed saves are surfaced, and the UI returns to its last valid snapshot rather than claiming persistence.

The app directory is private (`0700`) and app-written config files use `0600`. Reads are bounded to 1 MiB, and symlink/nonregular config files are refused. External editors may choose different file modes; the enclosing directory remains private. The JSON is not separately encrypted and may contain personal dictionary terms, vocabulary, and microphone identifiers. No network synchronization is performed.

The explicit packaged command `Sotto --prepare-config` creates/migrates or validates the file without opening the microphone or installing a hotkey. `--correct-text /path/to/text.txt [--config /path/to/config.json]` reads the chosen config (the normal config when omitted) without saving/migrating it. `--transcribe /path/to/audio.wav --config /path/to/config.json` reads that snapshot and applies dictionary/proofreading. Without `--config`, file transcription keeps its earlier Whisper/formatter behavior and does not read app preferences. These commands never download models or install a hotkey. File transcription saves history only with explicit `--archive-root`; text-only correction never creates audio history.
