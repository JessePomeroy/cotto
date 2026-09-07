# Sotto launch film · Work in progress

51 seconds · 1920 × 1080 · 30 fps. The film starts with **Hold. Speak. Release.** and covers local transcription, spoken lists, dictionary spelling, optional proofreading, microphone priorities, and local history. The opening brand scene has been removed.

The draft MP4 is checked in at [renders/sotto-launch.mp4](renders/sotto-launch.mp4). Microphone and history demos use illustrative sample data; animation timing is editorial, not a performance measurement.

## Preview

From this directory, run `python3 serve.py`, then open [localhost:4327](http://localhost:4327). The page includes chapters and an MP4 download. No installation is needed to watch the saved video.

## Edit and render

On macOS, install Node.js 22.12 or newer, Python 3, and FFmpeg, then run:

```sh
npm ci
npm run check
npm run render
```

- `index.html` contains the Hyperframes composition and its paused GSAP timeline. All cues start at zero in the edited 51-second timeline.
- `film.css` contains the visual design. `prepare-assets.mjs` copies installed macOS fonts and GSAP into ignored local assets for rendering. Font binaries are not included in the repository.
- `preview.html` and `serve.py` provide the small local viewer with video byte-range support.
- `assets/score.m4a` is the original instrumental soundtrack, trimmed to the new opening with a short fade-in. `generate-score.py` regenerates it with NumPy and FFmpeg; this is optional when using the checked-in audio.
- Ribbon and icon assets come from `brand-lab/concepts/sotto`. The dictionary still uses a native SwiftUI preview with synthetic content.

## Chapters

| Time | Feature |
| --- | --- |
| 0:00 | Dictation |
| 0:09 | Privacy and local transcription |
| 0:16 | Spoken lists |
| 0:24 | Dictionary and optional proofreading |
| 0:31 | Microphone priorities |
| 0:38 | Local history |
| 0:45 | Sotto |

The video is a working draft; the native app is the source of truth for behavior and controls.
