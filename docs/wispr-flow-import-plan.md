# Import Wispr Flow history into Soto

The current feature reads this Mac's Wispr Flow database and its complete local backups. It previews the recoverable rows, then imports only after an explicit click. The import archives source fields and media without running Soto's models or changing Wispr Flow. Choosing an arbitrary SQLite file or ingesting an account export remains future work.

## Goal and source

Add **Import from Wispr Flow** to Soto's History page. Read historical dictations from this Mac's Wispr Flow `flow.sqlite` without changing the source database, then archive the recoverable text, media, and source fields on the Soto server. This is an archive import: it must not run Soto's speech or cleanup models, paste old text, or delete source data.

[WisprSync](https://github.com/fjooord/WisprSync) is a useful reference for database discovery, `History`/`Dictionary` field names, and media extraction. It exports local SQLite to files; it does not import into Soto. Its current export omits several selected fields and `opusChunks`, so Soto should read SQLite directly and preserve unmapped source values. A WisprSync archive or another SQLite file can be a later fallback source.

Wispr Flow documents that dictation history is local to each device and is not exposed by its MCP connector. The button can only recover rows present in an accessible local database, backup, or separately obtained export. There is no documented bulk account-history export format to build against today.

## Phase 1 — source snapshot and preview

1. Add a macOS source reader near `Sources/Sotto/` that discovers `~/Library/Application Support/Wispr Flow/flow.sqlite` and inspects `History` and `Dictionary` by column name. Do not assume every installed Wispr Flow version has the same columns. A manually chosen `.sqlite` file can be added later.
2. Take a consistent **read-only SQLite snapshot** into Soto's private temporary directory before parsing. Prefer SQLite's backup API; handle a live WAL correctly and report snapshot failures rather than silently reading an inconsistent file. Never write into Wispr Flow's application-support directory.
3. Build a preview with the source date range and separate counts for nonempty transcripts, empty-text/failed attempts, WAV audio, screenshots, dictionary entries, and already-imported source IDs. Show estimated transfer/storage bytes and the chosen destination server. Build the preview locally; a server deduplication check sends source IDs only, without transcript or context data.
4. Scan complete Wispr Flow backups as well as the live database. Key rows by `transcriptEntityId`; prefer the current row for display and fill missing fields/media from older rows. A backup can restore media even when it adds no session IDs. Retain source row variants with their database provenance. Ignore incomplete `.tmp` backup files.

The source reader should iterate rows rather than loading all media blobs at once. `History.audio` is a WAV blob and `History.screenshot` is a PNG blob when present; validate actual file headers, format, and size before archiving. Preserve `opusChunks` even when WAV audio is also present.

## Phase 2 — faithful archival record

Extend [`GenerationRecord`](../Sources/SottoAPI/API.swift) with an optional source descriptor. Keep the existing live-recording fields compatible with old metadata; source status and settings must be labeled as **Wispr Flow source data**, not presented as Soto inference details. Imported records must be excluded from recording continuation and delivery logic.

```swift
struct ImportedSource: Codable, Equatable, Sendable {
    var provider: String          // "wispr-flow"
    var sourceID: UUID            // History.transcriptEntityId
    var sourceStatus: String?
    var importedAt: Date
    var variantNames: [String]
    var artifactNames: [WisprFlowArtifactName]
}
```

For the default History text, use nonempty `pastedText` (what Flow inserted), falling back to `serverFinalizedText`, `formattedText`, then `asrText`. Keep **all** text variants, edits, timing, language, app/URL, quality/feedback, and unknown source columns in a separate `source.json` artifact so later code can remap them. Preserve SQLite value types and nulls; encode unknown binary columns as base64 in that JSON. Keep one canonical attachment per media type (`source.wav`, `screenshot.png`, and `opus.json`); source JSON records hashes and byte counts for other backup versions. The available local media versions are byte-identical where they overlap. If a later rerun finds different media bytes, Soto preserves the earlier attachment and reports the session as partial, since the alternate bytes are not archived. This avoids bloating Soto's `metadata.json`, which startup currently limits to 1 MiB. A row with no usable text or audio remains a labeled metadata-only source attempt; do not count it as a recovered dictation.

Keep Wispr Flow dictionary state as an import artifact. Any change to Soto's active dictionary should be a separate previewed merge, because it changes future dictations and Soto's dictionary has its own limits and conflict rules.

## Phase 3 — server import path and safe reruns

Add authenticated import routes in [`SottoHTTPServer.swift`](../Sources/SottoServerKit/SottoHTTPServer.swift) and archival writes in [`GenerationService.swift`](../Sources/SottoServerKit/GenerationService.swift). The existing `POST /v1/generations` and audio/finish routes require a live recording and model readiness, so they must not be reused for historical rows. The server cannot open a client-side Wispr Flow path, especially when it runs on another machine.

Use a bounded per-session protocol: send a small manifest and display text, upload allowlisted files with byte counts/checksums, then commit. Validate source ID, dates, text sizes, file signatures, attachment limits, and checksums on the server. Place files in a private staging directory, write metadata last, atomically move the complete directory under `generations/<UUID>/`, then publish it in memory. Extend the artifact endpoint's allowlist for typed imported files; never accept arbitrary filesystem paths from the client.

Index `(provider, sourceID)` at server startup. Repeated imports skip unchanged records and **enrich** existing imports when a later source supplies more fields or media; they never remove already archived data merely because it disappeared from Flow. Show imported, enriched, skipped, and failed counts with a source ID for the first failure so an interrupted run can resume. Keep import-run diagnostics free of transcript text and source context.

## Phase 4 — History UX and verification

Add the button, preview sheet, progress/cancel state, and import summary to [`HistoryPage.swift`](../Sources/Sotto/Views/HistoryPage.swift), with orchestration in [`SottoController.swift`](../Sources/Sotto/SottoController.swift) and transport in [`ServerClient.swift`](../Sources/Sotto/ServerClient.swift). Show an **Imported from Wispr Flow** label, source text variants, and available attachment actions in detail. Add a source filter so imported sessions remain findable among the existing 50-record History pages. Keep the list's dimensions steady while preview/progress changes.

Verify with synthetic SQLite fixtures covering text-only rows, audio rows, metadata-only attempts, duplicate IDs across backups, a WAL-mode source, and reruns that enrich rather than duplicate. Confirm preview counts and media extraction against read-only local snapshots; leave the actual import to the user's explicit test. Preserve Soto's existing `swift test` and server checks.

## Recovery boundary

The normal button can archive only data still present in the selected local source files. Deleted rows, sessions from another device, and earlier account history require an older device database, an existing WisprSync export, or a support-provided account data copy. Wispr Flow does not publish a guaranteed bulk dictation-export format, so support-data ingestion should be designed after a real file is available. SQLite free pages are not a reliable source for the button.

Source references: [WisprSync's SQLite reader](https://github.com/fjooord/WisprSync/blob/8f24c4af5042fbb4d2d1de2348e8dd07b6aafc1a/wisprsync/source/sqlite.py), [source field/media shape](https://github.com/fjooord/WisprSync/blob/8f24c4af5042fbb4d2d1de2348e8dd07b6aafc1a/docs/10-system-design/10-data-structure/10-wispr-flow-source-shape.md), [Wispr Flow's local-history sync guide](https://docs.wisprflow.ai/articles/5284722493-sync-flow-across-your-devices), and [account-data access notice](https://wisprflow.ai/ccpa-notice).
