# Third-party notices

cotto is derived from [Sotto](https://github.com/davis7dotsh/sotto). The original
MIT license and copyright notice are preserved in [LICENSE](LICENSE).

## Native Linux desktop

- **Qt 6** supplies Core, Gui, Quick, QuickControls2, Multimedia, Network, DBus,
  and Widgets. Use dynamically linked distribution libraries. Redistributors must
  satisfy the licenses and notice obligations of the Qt modules/plugins they ship.
  Tests additionally use Qt Test and QuickTest.
- **libsamplerate**, BSD-2-Clause, converts selected microphone audio to the 16 kHz
  inference stream. The client requires 0.2.2 or newer. The license is retained in
  [Linux/licenses/libsamplerate-COPYING](Linux/licenses/libsamplerate-COPYING).
- KDE portals and **wl-clipboard** are external runtime tools, not vendored copies.
  Distribute them through the platform package manager and preserve their licenses
  if including them in a future bundle.

## Native inference

- **whisper.cpp / ggml**, MIT, pinned to v1.9.3
  (`371b5a7561823ab2bb32142d2751e35e7534727b`):
  [source and license](https://github.com/ggml-org/whisper.cpp).
- **llama.cpp / ggml**, MIT, pinned to b10516
  (`b95502ba9aa0eb73a2f4fc8878d7fbe6a847a0b9`):
  [source and license](https://github.com/ggml-org/llama.cpp).
- The helpers link these libraries statically and preserve their bundled dependency
  notices. Whisper's JSON decoder uses nlohmann/json v3.11.2; llama.cpp vendors
  nlohmann/json v3.12.0, both MIT. The retained JSON notice is in
  [Resources/JSON-LICENSE.txt](Resources/JSON-LICENSE.txt); additional notices remain
  with the pinned vendor source.
- **miniaudio / dr_wav**, MIT No Attribution option, copyright David Reid. Only
  file decoding is used; its notice is in
  [Resources/miniaudio-LICENSE.txt](Resources/miniaudio-LICENSE.txt).

Vendored dependencies retain upstream source for multiple platforms. That does not
add macOS support or a Swift toolchain requirement to cotto's Linux builds.

## Model resources

- **Whisper large-v3-turbo**, MIT. [Model](https://huggingface.co/openai/whisper-large-v3-turbo)
  and [GGML conversion](https://huggingface.co/ggerganov/whisper.cpp). The download
  revision and SHA-256 are pinned in `scripts/download-model.sh` and
  `Server/src/inference/model-pins.ts`. Notice: `Resources/Whisper-model-LICENSE.txt`.
- **Qwen3-4B-Instruct-2507 Q4_K_M**, Apache-2.0.
  [Official model](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) and pinned
  [Unsloth conversion](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/tree/a06e946bb6b655725eafa393f4a9745d460374c9).
  Notice: `Resources/Qwen-LICENSE.txt`. Models are downloaded separately, not
  committed or automatically fetched by the runtime.
- **Silero VAD**, MIT. [Upstream](https://github.com/snakers4/silero-vad) and
  [GGML conversion](https://huggingface.co/ggml-org/whisper-vad). The small detector
  is pinned by `scripts/download-vad.sh` and included in complete server packages.
  Notice: `Resources/Silero-LICENSE.txt`.

## Bun and TypeScript server

- **Bun 1.4.2**, MIT, embeds its Linux runtime in the compiled server. Its full
  upstream runtime acknowledgements, including JavaScriptCore/WebKit and linked
  libraries, are retained in `Resources/bun-LICENSE.txt`.
- **Fastify 5.12.4**, MIT; **Ajv 8.20.0** and **ajv-formats 3.0.1**, MIT;
  **YAML 2.8.1**, ISC. Direct pins are in `Server/package.json`; transitive pins
  are in `bun.lock`. `Server/scripts/licenses.ts` collects installed runtime
  dependency notices into packaged `resources/javascript-LICENSES.txt`.
- **openapi-typescript**, TypeScript, Prettier, and their development dependencies
  generate/check source and are not part of the installed desktop or server runtime.
  Versions and licenses remain in the package manifests and lockfile.

The removed Swift/macOS implementation and its unused dependencies are not shipped.
The remaining source and resources retain all applicable upstream notices. Cotto is
independent and is not affiliated with its model providers or upstream libraries.
