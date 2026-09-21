// Opt-in capability probe against an installed Pi, not a loaded extension.
// No provider, session, terminal, socket, or desktop connection is started.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";

const packageDirectory = process.argv[2];
if (!packageDirectory) {
  throw new Error("Usage: node Linux/tests/PiEditorProbe.mjs /path/to/pi-coding-agent");
}
const root = resolve(packageDirectory);
const { version } = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
const { Editor } = await import(pathToFileURL(join(root,
  "node_modules/@earendil-works/pi-tui/dist/components/editor.js")).href);
const identity = (text) => text;
const theme = { borderColor: identity, selectList: {
  selectedPrefix: identity, selectedText: identity, description: identity,
  scrollInfo: identity, noMatch: identity,
} };
// Only the renderer is a stub; editing uses the installed Pi editor code.
const renderer = { requestRender() {}, terminal: { rows: 30, columns: 100 } };
const editor = new Editor(renderer, theme);
const neighbor = new Editor(renderer, theme);
let submissions = 0;
editor.onSubmit = () => { submissions += 1; };
neighbor.onSubmit = () => { submissions += 1; };
editor.setText("left right");
neighbor.setText("another pane");
editor.render(100);
for (let index = 0; index < 5; index += 1) editor.handleInput("\x1b[D");
assert.deepEqual(editor.getCursor(), { line: 0, col: 5 });
editor.insertTextAtCursor("Café 日本語 😀 ");
assert.equal(editor.getExpandedText(), "left Café 日本語 😀 right");
assert.equal(neighbor.getExpandedText(), "another pane");
assert.equal(submissions, 0);

// Even line breaks are inserted as data by this primitive, not dispatched as
// Enter. Sotto's first delivery policy still rejects multiline/control text.
editor.insertTextAtCursor("first\nsecond");
assert.equal(editor.getExpandedText(), "left Café 日本語 😀 first\nsecondright");
assert.equal(submissions, 0);
console.log(`Pi ${version}: direct cursor insertion preserved text and neighboring editor; zero submissions.`);
console.log("Capability probe only: no live Pi/Herdr focus or delivery verification.");
