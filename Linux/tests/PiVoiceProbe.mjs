// Real installed Pi editor + real Qt bridge. Only the host and transcription
// source are fixtures. No microphone, provider, live Pi/Herdr, or desktop input.
import assert from "node:assert/strict";
import { mock } from "bun:test";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

if (!process.argv[2] || !process.argv[3])
  throw new Error(
    "Usage: bun Linux/tests/PiVoiceProbe.mjs /path/to/pi /path/to/sotto-pi-bridge-tests",
  );
const host = resolve(process.argv[2]);
const { CustomEditor } = await import(
  pathToFileURL(join(host, "dist/modes/interactive/components/custom-editor.js")).href
);
const { KeybindingsManager } = await import(
  pathToFileURL(join(host, "dist/core/keybindings.js")).href
);
const tuiLibrary = await import(
  pathToFileURL(join(host, "node_modules/@earendil-works/pi-tui/dist/index.js")).href
);
const { matchesKey, isKeyRelease } = tuiLibrary;
const { getAgentDir } = await import(pathToFileURL(join(host, "dist/config.js")).href);
mock.module("@earendil-works/pi-coding-agent", () => ({ CustomEditor, getAgentDir }));
mock.module("@earendil-works/pi-tui", () => tuiLibrary);
const { default: extension } = await import("../integrations/pi/voice.ts");
const createQuestionUi = process.argv[4]
  ? (await import(pathToFileURL(resolve(process.argv[4])).href)).createQuestionUi
  : undefined;
const bus = new EventEmitter();
const eventBus = {
  on: (name, listener) => {
    bus.on(name, listener);
    return () => bus.off(name, listener);
  },
  emit: (name, data) => {
    bus.emit(name, data);
  },
};
const directory = await mkdtemp("/tmp/sotto-voice-probe-");
const prior = process.env.SOTTO_PI_SOCKET;
const priorRuntime = process.env.XDG_RUNTIME_DIR;
process.env.XDG_RUNTIME_DIR = directory;
await mkdir(join(directory, "cotto-status"), { mode: 0o700 });
const recordingPath = join(directory, "cotto-status", "recording.json");
const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
process.env.PI_CODING_AGENT_DIR = join(directory, "pi-config");
const preferencePath = join(process.env.PI_CODING_AGENT_DIR, "sotto-voice.json");
process.env.SOTTO_PI_SOCKET = join(directory, "input.sock");
const fixture = spawn(resolve(process.argv[3]), ["--fixture", process.env.SOTTO_PI_SOCKET], {
  stdio: ["ignore", "pipe", "pipe"],
});
console.log(`Isolated Qt fixture PID: ${fixture.pid}`);
let output = "";
fixture.stdout.on("data", (data) => {
  output += data;
});
fixture.stderr.on("data", (data) => {
  output += data;
});
async function until(check) {
  const end = Date.now() + 3000;
  while (!check()) {
    if (Date.now() > end) throw new Error(`Timed out: ${output}`);
    await Bun.sleep(2);
  }
}
const identity = (text) => text;
const theme = {
  borderColor: identity,
  selectList: {
    selectedPrefix: identity,
    selectedText: identity,
    description: identity,
    scrollInfo: identity,
    noMatch: identity,
  },
};
const renderer = { requestRender() {}, terminal: { rows: 30, columns: 100 } };
const keys = new KeybindingsManager();
const commands = new Map(),
  events = new Map(),
  shortcuts = new Map();
let editor = new CustomEditor(renderer, theme, keys);
let factory, listener, status, questionUi;
let submissions = 0;
let idle = true;
const notifications = [];
editor.onSubmit = () => submissions++;
editor.focused = true;
const ctx = {
  mode: "tui",
  isIdle: () => idle,
  hasPendingMessages: () => false,
  ui: {
    notify: (message, level) => notifications.push({ message, level }),
    setStatus: (_key, value) => {
      assert.ok(
        value === undefined || value === "○" || value === "●",
        "Footer must contain only the indicator",
      );
      status = value;
    },
    getEditorText: () => editor.getExpandedText(),
    setEditorText: (text) => editor.setText(text),
    getEditorComponent: () => factory,
    setEditorComponent: (next) => {
      const text = editor.getText(),
        submit = editor.onSubmit,
        change = editor.onChange;
      editor.focused = false;
      factory = next;
      editor = next ? next(renderer, theme, keys) : new CustomEditor(renderer, theme, keys);
      editor.onSubmit = submit;
      editor.onChange = change;
      editor.onExtensionShortcut = (data) => {
        for (const [key, shortcut] of shortcuts) {
          if (matchesKey(data, key)) {
            void shortcut.handler(ctx);
            return true;
          }
        }
        return false;
      };
      editor.setText(text);
      editor.focused = true;
    },
    onTerminalInput: (callback) => {
      listener = callback;
      return () => {
        listener = undefined;
      };
    },
  },
};
const sendKey = (data) => {
  const result = listener?.(data);
  if (!result?.consume && !isKeyRelease(data)) (questionUi ?? editor).handleInput(data);
};
const press = () => sendKey("\x1b[114:82;6:1u");
const release = () => sendKey("\x1b[114:82;6:3u");
const toggle = () => {
  press();
  release();
};
const neighbor = new CustomEditor(renderer, theme, keys);
neighbor.setText("untouched neighbor");
try {
  await until(() => output.includes("ready"));
  const install = () => {
    commands.clear();
    events.clear();
    shortcuts.clear();
    extension({
      events: eventBus,
      registerCommand: (name, command) => commands.set(name, command),
      registerShortcut: (key, value) => shortcuts.set(key, value),
      on: (name, handler) => events.set(name, handler),
    });
    assert.equal(commands.get("sotto").handler, commands.get("cotto").handler);
    return commands.get("cotto");
  };
  let command = install();
  await events.get("session_start")({}, { ...ctx, mode: "rpc" });
  await command.handler("on", { ...ctx, mode: "rpc" });
  assert.equal(factory, undefined);
  editor.setText("preserve draft");
  await events.get("session_start")({}, ctx);
  assert.equal(factory, undefined);
  assert.equal(editor.getText(), "preserve draft");
  editor.setText("");
  const foreign = (tui, theme, keys) => new CustomEditor(tui, theme, keys);
  ctx.ui.setEditorComponent(foreign);
  await events.get("session_start")({}, ctx);
  assert.equal(factory, foreign);
  ctx.ui.setEditorComponent(undefined);
  const beforeStartup = output;
  await events.get("session_start")({}, ctx);
  assert.ok(factory);
  assert.equal(status, "○", "Ready without recording");
  await Bun.sleep(30);
  assert.equal(output, beforeStartup, "Startup must not request capture");
  await assert.rejects(stat(preferencePath), { code: "ENOENT" });
  await writeFile(recordingPath, JSON.stringify({ v: 1, recording: true, updatedAt: Date.now() }), { mode: 0o600 });
  await until(() => status === "●");
  assert.equal(output, beforeStartup, "Observing global recording must not request Pi capture");
  assert.equal(editor.getText(), "", "Observing recording cannot change the draft");
  await writeFile(recordingPath, JSON.stringify({ v: 1, recording: false, updatedAt: Date.now() }), { mode: 0o600 });
  await until(() => status === "○");
  // Compaction does not reload extensions or emit session_start. Readiness
  // must survive it (including an aborted attempt), without replacing a draft.
  editor.setText("draft survives compaction");
  const beforeCompactionFactory = factory;
  await events.get("session_before_compact")({}, ctx);
  assert.equal(factory, beforeCompactionFactory, "Compaction must not uninstall dictation");
  assert.equal(status, "○");
  assert.equal(editor.getText(), "draft survives compaction");
  assert.equal(output, beforeStartup, "Compaction must not start capture");
  editor.setText("left right");
  editor.render(100);
  for (let count = 0; count < 5; count++) sendKey("\x1b[D");
  press();
  await until(() => status === "●");
  sendKey("\x1b[114;6:2u"); // Correctly tagged repeats are consumed too.
  sendKey("\x1b[57442;1:3u"); // Modifier release must not rearm R.
  sendKey("\x1b[115;1:3u"); // Nor an unrelated key release.
  for (let count = 0; count < 29; count++) press(); // Herdr labels repeats as presses.
  assert.equal(status, "●", "A held chord must not stop recording");
  sendKey("\x1b[114;1:3u"); // R released after modifiers changed.
  press();
  assert.equal(status, "○", "Processing is not recording");
  press(); // Holding the stop chord must not cancel processing.
  await until(() => output.includes("receipt:inserted"));
  assert.equal(editor.getExpandedText(), "left café 世界right");
  assert.equal(status, "○");
  press(); // Completion must not rearm a key that is still held.
  await Bun.sleep(30);
  await command.handler("status", ctx);
  assert.match(notifications.at(-1).message, /cotto: Inserted/);
  release();
  assert.equal(submissions, 0);
  assert.equal(neighbor.getText(), "untouched neighbor");
  await Bun.sleep(30);

  const priorText = editor.getExpandedText();
  toggle();
  await until(() => status === "●");
  toggle();
  editor.setText("changed while transcribing");
  await until(() => notifications.at(-1)?.message.includes("Blocked"));
  assert.equal(status, "○");
  assert.equal(notifications.at(-1).level, "warning");
  assert.equal(editor.getExpandedText(), "changed while transcribing");
  await until(() => output.includes("receipt:blocked"));
  await Bun.sleep(30);

  editor.setText(priorText);
  press();
  await until(() => status === "●");
  sendKey("\x1b[D");
  assert.equal(status, "○");
  press(); // Missing release: other input/cancellation must not guess a rearm.
  await Bun.sleep(30);
  await command.handler("status", ctx);
  assert.match(notifications.at(-1).message, /cotto: Cancelled/);
  release();
  assert.equal(editor.getExpandedText(), priorText);
  await Bun.sleep(30);

  // A post-mutation callback failure must surface separately, never as footer text.
  const previousOnChange = editor.onChange;
  editor.onChange = () => {
    throw new Error("Observer failed after mutation");
  };
  toggle();
  await until(() => status === "●");
  toggle();
  await until(() => output.includes("receipt:uncertain"));
  assert.notEqual(editor.getExpandedText(), priorText);
  assert.equal(status, "○");
  assert.match(notifications.at(-1).message, /Insertion uncertain/);
  assert.equal(notifications.at(-1).level, "warning");
  editor.onChange = previousOnChange;
  editor.setText(priorText);
  await Bun.sleep(30);

  for (const event of [
    "session_before_switch",
    "session_before_fork",
    "session_before_tree",
    "session_before_compact",
  ]) {
    const savedFactory = factory;
    toggle();
    await until(() => status === "●");
    await events.get(event)();
    assert.equal(status, "○", `${event} cancels active capture`);
    assert.equal(
      factory,
      savedFactory,
      `${event} preserves readiness if the operation is cancelled`,
    );
    assert.ok(listener);
    await Bun.sleep(30);
    assert.equal(editor.getExpandedText(), priorText, "Cancelled takes cannot insert late");
  }
  await events.get("session_shutdown")();
  assert.equal(factory, undefined);
  assert.equal(listener, undefined);
  editor.setText("");
  await events.get("session_start")({}, ctx);
  assert.ok(factory, "Session replacement restores default readiness");
  idle = false;
  toggle();
  await until(() => notifications.at(-1)?.message.includes("Blocked"));
  assert.equal(status, "○");
  idle = true;
  toggle();
  await events.get("session_shutdown")();
  await Bun.sleep(30);
  assert.equal(factory, undefined);
  assert.equal(listener, undefined);
  assert.equal(submissions, 0);

  if (createQuestionUi) {
    editor.setText("");
    await events.get("session_start")({}, ctx);
    editor.setText("main draft must stay untouched");
    idle = false; // A tool is waiting on the user, not an idle agent editor.
    for (const options of [undefined, [{ label: "First" }, { label: "Second" }]]) {
      const answers = [];
      await events.get("ui_prompt_start")({ kind: "custom" });
      questionUi = createQuestionUi(
        { question: "Answer by voice", options },
        renderer,
        { fg: (_color, text) => text, bold: identity },
        (answer) => answers.push(answer),
        undefined,
        (id) => eventBus.emit("cotto:question-invalidated:v1", id),
      );
      const unsubscribe = eventBus.on("cotto:question-target:v1", ({ provide }) =>
        provide(questionUi.dictation),
      );
      const ambiguous = eventBus.on("cotto:question-target:v1", ({ provide }) =>
        provide(questionUi.dictation),
      );
      toggle();
      assert.match(notifications.at(-1).message, /cannot identify/);
      assert.equal(status, "○");
      ambiguous();
      const priorReceipts = (output.match(/receipt:inserted/g) ?? []).length;
      toggle();
      await until(() => status === "●");
      toggle();
      await until(() => (output.match(/receipt:inserted/g) ?? []).length > priorReceipts);
      assert.equal(questionUi.dictation.snapshot().text, "café 世界");
      assert.equal(answers.length, 0, "Dictation must never submit a question answer");
      assert.equal(editor.getExpandedText(), "main draft must stay untouched");
      assert.match(questionUi.render(100).join("\n"), /café 世界/);
      await Bun.sleep(30);
      toggle();
      await until(() => status === "●");
      questionUi.focused = false;
      assert.equal(status, "○", "Losing dialog focus cancels capture");
      questionUi.focused = true;
      await Bun.sleep(30);
      assert.equal(questionUi.dictation.snapshot().text, "café 世界");
      sendKey("\r"); // Only an explicit user Enter submits the text/custom answer.
      assert.equal(answers.length, 1);
      assert.equal(answers[0][0].type, options ? "other" : "text");
      questionUi.dispose();
      questionUi = undefined;
      unsubscribe();
      await events.get("ui_prompt_end")({ kind: "custom" });
      await Bun.sleep(30);
    }
    const abort = new AbortController();
    const cancelledAnswers = [];
    await events.get("ui_prompt_start")({ kind: "custom" });
    questionUi = createQuestionUi(
      { question: "Abort during processing" },
      renderer,
      { fg: (_color, text) => text, bold: identity },
      (answer) => cancelledAnswers.push(answer),
      abort.signal,
      (id) => eventBus.emit("cotto:question-invalidated:v1", id),
    );
    const unsubscribe = eventBus.on("cotto:question-target:v1", ({ provide }) =>
      provide(questionUi.dictation),
    );
    const receiptsBeforeAbort = (output.match(/receipt:inserted/g) ?? []).length;
    toggle();
    await until(() => status === "●");
    toggle();
    abort.abort(); // No terminal input: lifecycle invalidation must cancel on its own.
    assert.deepEqual(cancelledAnswers, [null]);
    assert.equal(questionUi.dictation.snapshot(), undefined);
    await Bun.sleep(60);
    assert.equal((output.match(/receipt:inserted/g) ?? []).length, receiptsBeforeAbort);
    assert.equal(editor.getExpandedText(), "main draft must stay untouched");
    questionUi.dispose();
    questionUi = undefined;
    unsubscribe();
    await events.get("ui_prompt_end")({ kind: "custom" });
    await events.get("session_shutdown")();
    idle = true;
    assert.equal(bus.listenerCount("cotto:question-invalidated:v1"), 0);
    console.log(
      "PASS: actual question editor receives text while agent is busy; Other opens safely; main draft unchanged; no automatic answers.",
    );
  }

  // A fresh extension instance simulates reload/new-session memory loss. Only
  // the isolated preference file can carry the explicit off/on choice across it.
  editor.setText("");
  await command.handler("off", ctx);
  assert.equal(status, undefined, "Opt-out removes the indicator");
  assert.deepEqual(JSON.parse(await readFile(preferencePath, "utf8")), { enabled: false });
  command = install();
  await events.get("session_start")({}, ctx);
  assert.equal(factory, undefined);
  assert.equal(listener, undefined);
  await shortcuts.get("ctrl+shift+r").handler(ctx);
  assert.equal(factory, undefined, "Shortcut must not override opt-out");
  await command.handler("on", ctx);
  assert.ok(factory);
  assert.deepEqual(JSON.parse(await readFile(preferencePath, "utf8")), { enabled: true });
  await events.get("session_shutdown")();
  command = install();
  await events.get("session_start")({}, ctx);
  assert.ok(factory, "Re-enabled preference survives reload");
  await events.get("session_shutdown")();
  await writeFile(preferencePath, "{");
  command = install();
  await events.get("session_start")({}, ctx);
  assert.equal(factory, undefined, "Invalid preference must not silently enable");
  assert.match(notifications.at(-1).message, /could not be read/);
  await command.handler("on", ctx);
  assert.ok(factory);

  // An unwritable destination must not prevent immediate opt-out/cancellation.
  toggle();
  await until(() => status === "●");
  await rm(preferencePath);
  await mkdir(preferencePath);
  await command.handler("off", ctx);
  assert.equal(factory, undefined);
  assert.equal(listener, undefined);
  assert.match(notifications.at(-1).message, /off here.*could not be saved/);
  await command.handler("on", ctx);
  assert.equal(factory, undefined);
  assert.match(notifications.at(-1).message, /activation was not changed/);
  assert.equal(submissions, 0);
  console.log(
    "PASS: duplicate-press/release latch, modifier order and missing-release safety; icon-only footer; cotto command and legacy alias; default readiness without capture; persisted off/on across extension instances; draft/custom-editor/RPC protection; corrupt/unwritable preference guards; Qt wire → real Pi cursor insertion; native receipts; zero submissions; edit/input/session/agent-state guards.",
  );
} finally {
  await events.get("session_shutdown")?.();
  if (fixture.exitCode === null) {
    const exited = new Promise((resolve) => fixture.once("exit", resolve));
    fixture.kill("SIGTERM");
    await exited;
  }
  if (prior === undefined) delete process.env.SOTTO_PI_SOCKET;
  else process.env.SOTTO_PI_SOCKET = prior;
  if (priorRuntime === undefined) delete process.env.XDG_RUNTIME_DIR;
  else process.env.XDG_RUNTIME_DIR = priorRuntime;
  if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
  await rm(directory, { recursive: true, force: true });
}
