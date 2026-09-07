# Sotto brand lab

The original Murmur / Sotto / Tempo identity exploration, preserved as a standalone reference. It does not change or load the Mac app, models, settings, microphone, or transcript history. All illustrations are original SVG; system fonts and local files keep the board self-contained.

From the project root:

```sh
python3 -m http.server 4317 --bind 127.0.0.1 --directory brand-lab
```

Open **http://localhost:4317**. Choose a direction to update the app, menu, icon, palette, and logo specimens. Switch light/dark appearance, preview recording states, or play a simulated dictation. Star names and write direction-specific notes; those preferences stay in browser local storage. Color buttons copy hex values only when clicked. SVG packs download from the page.

- **Murmur** — continuity, a folded m, warm paper / evergreen ink / clay.
- **Sotto** — editorial intimacy, a ribbon S, plum / vermilion / blush.
- **Tempo** — a precise instrument, a turning t, petrol / cobalt / citrus.

Each concept has editable source SVGs and `concept.json` in `concepts/`. ZIPs in `downloads/` contain that direction's SVGs plus its concept notes. Names are creative candidates; availability has not been checked. Mock interfaces and example timing are illustrative, not a recording or performance measurement.

The shortlist, notes, simulated states, and appearance controls affect this board only. The initial recommendations are preserved for context; Sotto is the chosen identity.

## Sotto interface prototype

The connected Sotto UI exploration is at **http://localhost:4317/sotto/**, with source in `sotto/`. The original three-direction board is preserved.

- Choose **Menu bar**, **Listening**, **Settings**, or **Identity**. Light/dark affects the Mac mock, not the surrounding presentation.
- Hold **Space** outside a text field, hold the **fn** keycap, or click **Try a dictation**. Release the key to preview transcription, optional correction, and delivery. A click-started take can be finished with the microphone button on Dictation or in the menu. Escape cancels. Space is a browser stand-in for the actual app's global shortcut; the prototype does not capture Fn.
- The compact **200 × 46 px listening indicator** contains the ribbon logo, a simulated waveform or processing/result symbol, and a timer. Hover or keyboard focus reveals **×** in the timer’s space; Escape also cancels. It keeps the same dimensions across states.
- Microphone-name buttons start preview-only tests; input selection stays on the Microphone page. Regular dictation inserts a scripted sample in the editable example note or the **prototype clipboard**, according to the delivery selector. Only explicitly labeled copy buttons write to the real clipboard.
- Change microphone priorities and simulated connections, add/remove dictionary terms, toggle correction and memory, inspect sample history, and edit general preferences. The selected input and relevant settings are pinned for each mock take.
- All settings and added transcripts are in-memory sample data. Reset or reload restores defaults. No native app, real model, microphone, filesystem preferences, or existing transcript history is accessed. Sample durations/processing times do not benchmark the app.
- The native app implements this direction using the `Sotto` executable and modules. It preserves the `dev.davis.murmur` permission identity and existing `~/.murmur` configuration, models, and archives. The `~/.sotto/transcripts` path shown in the web prototype is illustrative; it is not a data migration. Native General retains the existing combined “Save transcripts and recordings” control. Naming availability has not been checked.

### Dark material study

**Glacier** is the native app’s chosen dark finish. It is now the default dark finish in this prototype; the other directions remain as references. Open **http://localhost:4317/sotto/?theme=dark&material=glacier** to compare:

- **Graphite** — neutral smoked glass and silver accents.
- **Glacier** — cool slate glass and ice-blue accents.
- **Moss** — charcoal glass and pale sage accents.
- **Original** — the previous plum/vermilion dark mode, retained as a reference.

The finish buttons switch the settings window, menu, listening indicator, and example desktop together. They preserve the current mock settings and any active simulated dictation. Light mode remains unchanged; the Identity tab retains the original brand specimens. Appearance and finish are stored in the preview URL, not native preferences or browser storage. Reset keeps the current appearance and finish while restoring sample data.

The new finishes use translucent shells and sidebars, restrained inset surfaces, and brighter rims on floating glass. Reduce Transparency uses opaque surfaces when supported by the browser. These are web-only explorations, not changes to the installed app.

These prototypes are design references, not native-app validation. The application’s
features and build instructions are in the [project README](../README.md).
