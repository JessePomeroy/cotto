# Native engine

Sotto launches this persistent `whisper.cpp` helper when it needs the model,
then terminates it to release the model and Metal allocations. It never opens a
microphone or a network connection. The app owns recording and model downloads.

Build from the project root:

```sh
cmake -S . -B .build/native -DCMAKE_BUILD_TYPE=Release
cmake --build .build/native --target sotto-engine -j 8
scripts/download-vad.sh
.build/native/Engine/sotto-engine --model /path/to/ggml-large-v3-turbo.bin --vad-model .build/models/silero-vad.bin
```

The process loads one model, then writes `{"type":"ready","engineVersion":"<whisper_version()>"}`. The version is retained in local history metadata. Send one JSON object
per line on stdin. Every response is a flushed JSON line on stdout. Diagnostics
go only to stderr; transcripts are not logged there.

```json
{"type":"transcribe","id":"request-1","path":"/private/tmp/recording.wav","language":"en","prompt":"Sotto, SwiftUI, Metal"}
```

- `language` defaults to `en`; `auto` enables language detection.
- `prompt` is optional vocabulary, not an instruction for rewriting text.
- WAV input must be mono, 16 kHz, PCM16 or float32, and 0.2–180 seconds long.
- Progress: `{"type":"progress","id":"request-1","value":0.5}`.
- Result: `{"type":"result","id":"request-1","text":"Hello.","duration":2.0,"elapsed":0.7,"language":"en"}`.
- Error: `{"type":"error","id":"request-1","message":"…"}`; startup and malformed-request errors may not have an id.
- Silence returns a successful result with empty text. A small, persistent
  CPU-only Silero VAD model rejects nonspeech before Whisper runs. The detector
  accepts speech segments of at least 120 ms at a 0.5 probability threshold.
  Recordings with speech are passed intact so quiet word boundaries are kept.
  Segments marked as no-speech by Whisper are also excluded.
- Requests run sequentially. Terminate the process to cancel an active request.
- `{"type":"quit"}`, stdin EOF, or parent-process exit releases the model. A
  blocking macOS process event watches the parent even during inference.

Metal, embedded Metal source, and Accelerate are enabled. All third-party code
is statically linked, so there are no adjacent dylibs or shader files to ship.
The WAV reader is the bundled dr_wav implementation inside `miniaudio.h`.

The decoder uses beam search (width 5) and preserves Whisper's punctuation. It
does not rewrite prose with an LLM, and speech detection remains probabilistic:
background speech can still be
transcribed, while very quiet speech can be missed. Review text before sending.
