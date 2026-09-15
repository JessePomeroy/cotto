# Shared history and artifacts

The server is the durable owner of every generation. All Macs connected to that server read the same history, tagged with the originating device ID and display name. The desktop has temporary capture/upload data, not a local transcript archive or offline retry queue.

## Layout

The runner accepts a persistent `--data-dir`; local development defaults to `.local/server`.

```text
<data-dir>/
  preferences.json
  generations/
    <generation-UUID>/
      metadata.json
      transcript.txt
      inference.wav
      original.wav
```

- `metadata.json` stores the generation's identity, device, mode, lifecycle status/timestamps, accepted preferences revision/snapshot, audio formats/frame counts, raw ASR, final text, insertion chunk, preview, processing/model provenance, continuation, errors, and any client delivery receipt.
- `transcript.txt` is UTF-8 final text for the current take. The accumulated preview can differ when a list spans several takes; the API exposes both.
- `inference.wav` is the complete mono 16 kHz float32 audio passed to Whisper.
- `original.wav` contains interleaved float32 PCM at the microphone's captured sample rate/channel count. It is present when the generation's accepted settings enable original retention.

Both audio versions are retained by default. **Server preferences → Keep original microphone audio** controls original upload/retention for future takes; inference audio remains retained. Changing the toggle does not remove previous artifacts. There is no automatic retention expiry for completed history in this version.

The server writes partial `.raw`/`.wav.partial` files while receiving/sealing audio. Those are working files, not downloadable artifacts. A generation must pass exact frame-count and matching-interval checks before inference. Failed or cancelled generations may have metadata without a transcript, and complete sealed audio can remain available for a failed processing attempt.

## Lifecycle and recovery

- A server-accepted generation exists before microphone capture. Offline or busy servers prevent the take from starting.
- Incomplete uploads expire after inactivity or the overall upload deadline; cancellation removes partial files. The client discards temporary audio when a capture/upload fails.
- Once the complete upload is sealed, processing can finish independently of the originating app. Reconnecting retrieves state; it never pastes a result automatically.
- On server restart, unfinished generations become failed. Completed records and artifacts survive. There is no automatic processing retry or offline recovery queue.
- Processing completion and delivery are separate facts. A completed generation can carry an `inserted`, `copied`, `unconfirmed`, or test/control outcome, or no receipt if the client disconnected before delivery.

The app's **History** page fetches paginated records, filters by device, copies text, and opens available audio. Opening audio downloads a temporary client copy for playback. Explicit history deletion removes the server generation and its artifacts; active generations cannot be deleted. Merely clearing the latest preview does not delete history.

## Portability and privacy

The storage format is shared by the Mac and Linux server. One runner owns a data directory. Keep it on durable storage and back up preferences and generation directories together. No database or cloud object store is required for this single-server version.

The API accepts generation IDs and allowlisted artifact names, never caller filesystem paths. Data routes require the configured bearer token. Files contain dictated speech, text, device names, dictionary terms, and settings; filesystem storage is not separately encrypted by Sotto. Remote transport uses private Tailscale access or HTTPS.

The new product does not read or import the installed app's old archive. Any future manual conversion of existing sessions is outside this implementation.

See [HTTP contract](client-server-contract.md) for record and artifact routes, and [configuration](configuration.md) for storage/retention settings.
