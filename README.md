# Sotto

**Hold a key. Speak. Let your server do the work.**

Sotto is a native macOS dictation client with an independent model server. Use the app on a lightweight Mac while another Mac or Linux machine runs speech recognition and proofreading. Client and server can also run together on one Mac through the same HTTP API.

This branch builds **Sotto Dev**, with a separate app identity and visible Dev labels. It is a new server-owned product: there is no legacy local mode, migration, or session importer.

## Dictation

- Hold Right Option, Right Control, or Fn/Globe to talk. Release to process the complete take and insert one finished result at the original cursor.
- Audio uploads while you speak. The app shows server status and processing progress; it does not type partial model output.
- The server must be ready and accept the take before the microphone starts. There is no offline recording or retry queue.
- Preferred microphone lists, shortcut, connection, and device name belong to each Mac. Dictionary, processing preferences, and history are shared through the server.
- History identifies the originating device and includes text, metadata, and audio. Original microphone audio and normalized Whisper audio are retained by default; **Keep original microphone audio** controls original retention for future takes.
- Confirmed cursor anchors preserve spoken-list continuation across takes. If the destination is no longer safe, delivery uses an appropriate clipboard or preview fallback.

The server can finish a completely uploaded take after the app disconnects or quits. Opening history later never inserts that result into another app. Quitting Sotto Dev leaves the independent server running.

## Model runtimes

| Server platform | Speech recognition | Optional proofreading |
| --- | --- | --- |
| Apple Silicon macOS | Whisper large-v3-turbo, whisper.cpp with Metal | Qwen3-4B-Instruct-2507, native Swift MLX with 4-bit weights |
| Linux x86_64 / ARM64 | Whisper large-v3-turbo, whisper.cpp | Qwen3-4B-Instruct-2507, llama.cpp with Q4_K_M GGUF |

Linux builds support CUDA and a CPU compatibility build. Models stay warm in the server. The app contains no model helpers or weights, and Windows is outside this version's scope. Weights must already be available to the server and match the pinned artifacts.

The target is a few seconds after release for typical dictation. Actual latency depends on the chosen server, model warmup, take length, and network upload capacity; CPU support does not imply that this latency target is met. See [server setup](Server/README.md) for native and container options.

## Build and try on this Mac

The native client targets macOS 14+ and currently builds with the macOS 26+ SDK. Building the Mac server requires Apple Silicon, Xcode with the Metal compiler, CMake, and Swift 6.2 or newer.

```sh
git submodule update --init --recursive
./scripts/build-server.sh
./scripts/build-dev-app.sh
./scripts/run-dev.sh start --skip-build
```

This opens `build/Sotto Dev.app` and runs the server at **http://localhost:8391**. The runner isolates device settings in `.local/client`. The scripts reuse existing pinned Whisper/MLX model weights when available; set `SOTTO_SPEECH_MODEL` and `SOTTO_TEXT_MODEL` to use other locations. No old sessions or settings are imported. See [server setup](Server/README.md) for the expected model paths and standalone runner arguments.

1. Grant **Sotto Dev** its own Microphone and Accessibility permissions. Separate Input Monitoring permission is not required.
2. Wait for **Server ready**. Fresh device preferences use **Right Option**; change the shortcut under **This Mac**.
3. Focus a text field, hold the shortcut, speak, and release. **Test microphone** previews a result inside Sotto without inserting it elsewhere.

For Fn/Globe, set macOS **Keyboard → Press Globe key to → Do Nothing** if its system action conflicts. The build does not replace an installed Sotto app. Signing uses an available Apple Development identity or ad-hoc signing; ad-hoc rebuilds may require granting permissions again.

```sh
./scripts/run-dev.sh status
./scripts/run-dev.sh stop
./scripts/run-dev.sh restart
swift test
./scripts/smoke-test.sh       # Real models through the running Dev HTTP server
./scripts/test-corrections.sh # Packaged proofreading helper and resources
```

The HTTP smoke test uses the public JFK fixture, temporarily toggles original-audio retention, restores shared preferences, and removes its test generations. Run it while the Dev server is idle. Add `--keep-results` to leave labeled samples in shared history.

## Connections and data

Use localhost on the same machine, a private Tailscale endpoint, or an HTTPS endpoint on a hosted server. Nonloopback server listeners require a bearer token; each client stores its credential in Keychain. The server API and data directory do not depend on Tailscale or a particular hosting provider.

- The server stores shared preferences and generation artifacts under its configured persistent data directory. The dev runner defaults to `.local/server`.
- The Mac normally stores device preferences under `~/Library/Application Support/Sotto Dev`. `SOTTO_CLIENT_DATA_DIR` selects another directory; the dev runner uses `.local/client`. Audio on the client is temporary capture/upload data.
- Audio, transcript text, and dictionary terms travel to the configured server. The server's filesystem is the durable source of truth and should be backed up accordingly.
- The microphone opens only for a recording you start, with a three-minute cap. The models do not receive surrounding documents, screenshots, or clipboard history.

Proofreading and insertion checks are conservative safeguards, not a guarantee of unchanged meaning or successful delivery. Review important text before sending.

[Architecture](docs/architecture.md) · [Configuration](docs/configuration.md) · [Shared history](docs/local-history.md) · [Text correction](docs/text-correction.md) · [HTTP contract](docs/client-server-contract.md)

## License

[MIT](LICENSE). Dependencies and model licenses are listed in [third-party notices](THIRD_PARTY_NOTICES.md).
