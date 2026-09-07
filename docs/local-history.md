# Local history

Sotto saves completed dictations in **`~/.murmur/transcripts`** when history is enabled. The directory retains the app’s original Murmur name for compatibility. Versions before 0.6.0 kept only the last transcript in memory and deleted capture audio; those versions have no older history to recover.

```text
~/.murmur/
  transcripts/
    2026-09-04/
      2026-09-04T18-42-10.123Z-<uuid>/
        transcript.txt
        metadata.json
        audio.wav
        transcription.wav
```

Dates, folder timestamps, and JSON timestamps use UTC. Each folder represents **one hold or in-app test**, not an entire multi-hold conversation or list. UUIDs prevent simultaneous timestamps from colliding. There is no database or proprietary export format.

## Files

| File | Contents |
| --- | --- |
| `transcript.txt` | The new text from this take, after cleanup, dictionary rules, list formatting, and any accepted local proofread. No prior list items or paste-only spacing. A list-control-only command or no-speech result can produce an empty file. |
| `metadata.json` | Schema version, ID, start/release/completion times, outcome, mode, raw ASR text, final formatted text, speech-model ID/name/SHA-256, engine/version, requested/detected language, cleanup setting, vocabulary prompt, microphone UID/name, audio formats/frame counts/durations, timings, app version/build, initial delivery status or processing error, and optional `textProcessing` details. |
| `audio.wav` | The PCM received from the selected microphone's input tap, retaining its sample rate, channels, and precision before Sotto's downmix/resampling. WAV storage interleaves channels in little-endian order. This is not a claim of bypassing processing already performed by hardware or macOS. |
| `transcription.wav` | The exact 16 kHz mono float32 WAV passed to the local Whisper helper. |

`startedAt` is the request to start recording; hardware opens asynchronously afterward. `releasedAt` is the stop request (including the three-minute limit). `completedAt` is the finalized transcription/delivery outcome, before archive copying. Actual audio duration comes from frame counts, not the interval between those timestamps.

`engineProcessingSeconds` measures the speech helper's inference work. `transcriptionWallSeconds` covers the Swift transcribe call, including any remaining speech-model-loading wait. `releaseToResultSeconds` covers release through capture finalization, transcription, dictionary/list formatting, optional proofreading, and delivery. Text-model work has separate `textProcessing.processingSeconds` and `wallSeconds` fields. Durations use monotonic time; wall-clock timestamps can change if the system clock is adjusted. A `null`/omitted optional timing means unavailable, not zero.

`outcome` is `transcribed`, `noSpeech`, or `failed`. A successful transcription can still have `deliveryStatus: "failed"` or `"unconfirmed"`: the archive does not pretend that text reached another app. Later Copy/Clear actions do not rewrite this initial record. The explicit file-transcription CLI uses `mode: "file"` with no microphone, and command timestamps rather than inventing the source recording's capture time.

## Text-processing metadata

Version 0.8 adds an optional `textProcessing` object. Older records remain readable without it. It describes only this take's dictated text, not surrounding document text or the accumulated multi-hold preview.

| Field | Meaning |
| --- | --- |
| `dictionaryTerms` | Preferred terms from the take's dictionary snapshot. This can include personal names even if they did not occur in the audio. |
| `dictionaryChangedText` | Whether the initial deterministic dictionary pass changed the cleaned ASR text. |
| `inputText` | Cleaned/dictionary-corrected/list-formatted source supplied to the optional proofread stage. |
| `outputText` | Accepted final chunk, or the same source when correction was disabled, unavailable, rejected, failed, or skipped. |
| `enabled` | The text-correction preference captured for this take. |
| `status` | `disabled`, `unavailable`, `applied`, `unchanged`, `rejected`, `failed`, or `skipped`. |
| `reason` | Optional explanation of fallback/rejection; not an insertion receipt. |
| `modelID`, `modelSHA256`, `engineVersion` | The configured text-model identity and available helper version. Their presence alone does not imply inference ran; inspect `status`. |
| `processingSeconds`, `wallSeconds` | Available native proofread time and wall time of the correction stage. |

`rawText` remains Whisper's unmodified recognition output; `transcriptText`/`transcript.txt` retain the final new chunk. A rejected model proposal is not substituted into `outputText`; the rejection reason and source remain auditable. No raw model reasoning, screenshots, target document text, or later manual corrections are collected. Proofreading is not automatic learning from the archive.

Configured file transcription (`--transcribe ... --config ... --archive-root ...`) also records this metadata. Without `--config`, the file CLI keeps its baseline speech/formatter path; without `--archive-root`, it writes no history. The text-only `--correct-text` command prints its processing record as JSON and does not create audio history.

## Browse saved dictations

Open **History** in the sidebar. The browser reads existing metadata on demand, initially listing up to **200** valid records; **Load more** expands the list in increments of 200. It does not load audio merely to display the list. The list and selected transcript each have a fixed-height scroll region.

- Select a take to read its transcript, date, duration, model, and microphone details.
- **Copy selected transcript** copies the saved text; it does not retry insertion into another app.
- **Reveal selected dictation in Finder** opens its take folder. **Open history folder** opens the archive root.
- **Open recording** opens the original `audio.wav` in the default audio player. It is unavailable when that file is missing; there is no in-app audio player or retranscription action in this pass.
- **Refresh history** reads changes made outside the app. Newly completed saves also refresh the list.

Browsing is read-only: it does not rewrite metadata, migrate folders, or delete files. Invalid, oversized, or unreadable metadata is skipped with a visible count. Metadata reads are limited to 1 MiB per file, and linked take directories or metadata files are not followed. Records with no speech or failed transcription can appear with their recorded outcome instead of invented text.

## Retention and controls

- **General → History → Save transcripts and recordings** defaults on. This is one combined control for transcripts and recordings, not separate retention switches. The setting is snapshotted at the start of each take. Turning it off stops future archival; it does not delete previous history.
- **Open history folder** opens the plain folder in Finder. Delete individual take folders or dated folders there. No automatic age/size pruning is applied. The History browser offers reading and file actions; deletion remains a Finder operation.
- Completed **microphone-name button tests** are saved too, but never pasted or copied automatically. Valid finished audio that yields no speech or a transcription failure is retained with that outcome.
- Cancelled takes, short accidental holds, and sleep/lock interruptions are discarded. Escape and modifier chords can cancel Option/Control takes; an accepted Fn hold continues through navigation and Escape until release or the explicit × action. Hardware/model startup errors or interruptions that prevent a completed capture also have no archive entry.
- **Clear** clears the live preview and list continuation, not files on disk. Quitting clears the preview but waits for already-queued history saves. A force quit, crash, or power loss can lose a take that has not finished saving; partial hidden staging folders may remain and can be deleted.
- Saving is off the UI/audio callback path and begins after delivery. A failed archive copy does not change the transcription/paste result. A visible **History needs attention** warning links to General; it stays until dismissed, even if a later take saves. Failed saves are not retried automatically, and temporary audio is discarded. The transcript remains in the live preview when available.

## Privacy and disk usage

All of this stays on this Mac: no upload, sync service, account, or telemetry. Archive directories have mode `0700`, files `0600`; Sotto rejects symlinks at archive directory leaves and audio sources rather than redirecting private data. Files are written to a private staging folder and published together with an exclusive rename, never overwriting an existing take. Sotto does **not** encrypt the archive itself. Anyone with access as this user, system administrators, or backup software may access it; system disk encryption and backup policies remain yours.

Audio is uncompressed for reusable training/evaluation/retranscription data. A 48 kHz mono float32 original plus its 16 kHz inference copy uses roughly **15 MB per minute**; stereo originals use more. Retention can grow without bound, so review the folder periodically. There are briefly both temporary and archived copies during a save.

The speech model remains in **`~/Library/Application Support/Murmur/Models`**; the optional proofreading model lives in **`~/.murmur/models`**. Since 0.7.0, settings and microphone priorities live in **`~/.murmur/config.json`**, migrated from macOS preferences (`dev.davis.murmur`); version 0.8 adds dictionary lists and the proofreading toggle there. See [configuration](configuration.md). The archive does not move or duplicate model weights. No destination document text, screenshots, keystrokes, or clipboard history are stored in these records.
