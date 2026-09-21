import {
  getAgentDir,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { isKeyRelease, isKeyRepeat, matchesKey, parseKey } from "@earendil-works/pi-tui";
import { join } from "node:path";
import { type InputTarget } from "./target.ts";
import { PiDictation, type DictationStatus } from "./dictation.ts";
import { SottoEditor } from "./editor.ts";
import { readVoiceEnabled, writeVoiceEnabled } from "./preferences.ts";
import { questionTarget, type QuestionTarget } from "./question.ts";
import { observeRecording } from "./recording-status.ts";

type EditorFactory = NonNullable<ReturnType<ExtensionContext["ui"]["getEditorComponent"]>>;
const shortcut = "ctrl+shift+r";
const labels: Record<DictationStatus, string> = {
  connecting: "Connecting to cotto…",
  starting: "Starting microphone…",
  recording: "Recording · Ctrl+Shift+R to stop",
  processing: "Transcribing · Ctrl+Shift+R to cancel",
  inserted: "Inserted into the claimed editor · not submitted",
  blocked: "Blocked · check the connection/editor or review the transcript in cotto",
  uncertain: "Insertion uncertain · check the claimed editor before copying",
  cancelled: "Cancelled",
};

class VoiceEditor extends SottoEditor {
  override handleInput(data: string): void {
    // Starting/stopping our take does not edit the draft. All other keys retain
    // CustomEditor's bindings and SottoEditor's invalidation behavior.
    if (matchesKey(data, shortcut) && this.onExtensionShortcut?.(data)) return;
    super.handleInput(data);
  }
}

// Ready by default in a safe TUI editor; recording still requires the shortcut.
export default function cottoVoice(pi: ExtensionAPI) {
  let modal = false;
  let latestStatus: DictationStatus | undefined;
  let state:
    | {
        ctx: ExtensionContext;
        factory: EditorFactory;
        client: PiDictation;
        cleanup: () => void;
        clearQuestion: () => void;
      }
    | undefined;
  const disable = () => {
    const old = state;
    state = undefined;
    if (!old) return;
    old.client.cancel();
    old.cleanup();
    if (old.ctx.ui.getEditorComponent() === old.factory) {
      const text = old.ctx.ui.getEditorText();
      old.ctx.ui.setEditorComponent(undefined);
      old.ctx.ui.setEditorText(text);
    }
    old.ctx.ui.setStatus("sotto", undefined);
  };
  const preferencePath = () => join(getAgentDir(), "sotto-voice.json");
  const enable = (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || state) return;
    if (ctx.ui.getEditorComponent() || ctx.ui.getEditorText().length > 0) {
      ctx.ui.notify(
        "Enable cotto with an empty default editor. Existing custom editors are not replaced.",
        "warning",
      );
      return;
    }
    const runtime = process.env.XDG_RUNTIME_DIR;
    const path =
      process.env.SOTTO_PI_SOCKET ??
      (runtime ? join(runtime, "sotto-dictation", "input.sock") : undefined);
    if (!path) {
      ctx.ui.notify("cotto requires a local private runtime socket.", "warning");
      return;
    }
    let editor: VoiceEditor | undefined;
    let question: QuestionTarget | undefined;
    let suspended = false;
    const factory: EditorFactory = (tui, theme, keys) => {
      editor?.invalidateClaim();
      editor = new VoiceEditor(tui, theme, keys);
      return editor;
    };
    const available = (): boolean =>
      state?.client === client &&
      !suspended &&
      !ctx.hasPendingMessages() &&
      ctx.ui.getEditorComponent() === factory &&
      (question ? modal && question.available() : !modal && ctx.isIdle());
    const target: InputTarget = {
      snapshot: () =>
        available() ? (question ? question.target.snapshot() : editor?.snapshot()) : undefined,
      apply: (expected, text) =>
        available() &&
        (question ? question.target.apply(expected, text) : !!editor?.apply(expected, text)),
    };
    let desktopRecording = false;
    const updateIndicator = () => ctx.ui.setStatus("sotto", desktopRecording || client.phase === "recording" ? "●" : "○");
    const client = new PiDictation(path, target, (status) => {
      latestStatus = status;
      updateIndicator();
      if (status === "blocked" || status === "uncertain") {
        ctx.ui.notify(`cotto: ${labels[status]}`, "warning");
      }
    });
    const stopObserving = runtime
      ? observeRecording(join(runtime, "cotto-status", "recording.json"), (recording) => {
          desktopRecording = recording;
          updateIndicator();
        })
      : () => {};
    const selectQuestion = () => {
      const candidates: QuestionTarget[] = [];
      let collecting = true;
      pi.events.emit("cotto:question-target:v1", {
        provide: (value: unknown) => {
          if (!collecting) return;
          const candidate = questionTarget(value);
          if (candidate?.available()) candidates.push(candidate);
        },
      });
      collecting = false;
      question = candidates.length === 1 ? candidates[0] : undefined;
      if (question?.activate()) return true;
      question = undefined;
      return false;
    };
    const clearQuestion = () => {
      client.cancel();
      question = undefined;
    };
    const unsubscribeQuestion = pi.events.on("cotto:question-invalidated:v1", (id: unknown) => {
      if (question?.id === id) {
        client.cancel();
      }
    });
    const toggle = () => {
      if (client.phase === "recording") client.stop();
      else if (client.active) client.cancel();
      else void client.start();
    };
    let shortcutPressed = false;
    const unsubscribe = ctx.ui.onTerminalInput((data) => {
      // Herdr can label repeats as presses. Only an observed R release rearms;
      // completion, cancellation, other keys and elapsed time are not releases.
      // Pi invokes this listener before its own Kitty key-up filtering.
      if (isKeyRelease(data)) {
        if (parseKey(data)?.split("+").at(-1)?.toLowerCase() === "r") shortcutPressed = false;
        return undefined;
      }
      if (matchesKey(data, shortcut)) {
        if (isKeyRepeat(data) || shortcutPressed) return { consume: true };
        shortcutPressed = true;
        if (modal) {
          if (!client.active) {
            // Ask the visible question for its capability now, not whichever
            // popup last registered. Ambiguous/late responses never select a target.
            if (!selectQuestion()) {
              ctx.ui.notify(
                "cotto cannot identify an enabled question answer editor here.",
                "warning",
              );
              return { consume: true };
            }
          }
          toggle();
          return { consume: true };
        }
        return undefined;
      }
      editor?.invalidateClaim();
      client.cancel();
      return undefined;
    });
    const resumed = () => {
      suspended = true;
      client.cancel();
    };
    process.on("SIGCONT", resumed);
    state = {
      ctx,
      factory,
      client,
      clearQuestion,
      cleanup: () => {
        stopObserving();
        unsubscribeQuestion();
        unsubscribe();
        process.off("SIGCONT", resumed);
      },
    };
    try {
      ctx.ui.setEditorComponent(factory);
      latestStatus = undefined;
      ctx.ui.setStatus("sotto", "○");
      ctx.ui.notify(
        "Pi-owned mode: cotto returns text only to the unchanged Pi editor you start from (draft or question answer). Desktop focus changes alone are not verified; this is not global active-field dictation.",
        "warning",
      );
    } catch {
      disable();
      ctx.ui.notify("cotto could not enable safely.", "error");
    }
  };
  pi.on("session_start", (_event, ctx) => {
    disable();
    if (ctx.mode !== "tui") return;
    try {
      if (readVoiceEnabled(preferencePath())) enable(ctx);
    } catch {
      ctx.ui.notify("cotto stays off: its saved preference could not be read.", "warning");
    }
  });
  pi.on("session_shutdown", disable);
  // These operations may be cancelled; compaction/tree navigation do not
  // restart extensions at all. Cancel the take, not future dictation readiness.
  const cancelTake = () => state?.clearQuestion();
  pi.on("session_before_switch", cancelTake);
  pi.on("session_before_fork", cancelTake);
  pi.on("session_before_tree", cancelTake);
  pi.on("session_before_compact", cancelTake);
  pi.on("agent_start", () => {
    state?.client.cancel();
  });
  pi.on("ui_prompt_start", () => {
    modal = true;
    state?.clearQuestion();
  });
  pi.on("ui_prompt_end", () => {
    state?.clearQuestion();
    modal = false;
  });

  pi.registerShortcut(shortcut, {
    description: "cotto: record/stop; cancel while transcribing. Never submits.",
    handler: async (_ctx) => {
      const client = state?.client;
      if (!client) {
        _ctx.ui.notify("Enable Pi-owned dictation with /cotto on first.", "info");
        return;
      }
      if (client.phase === "recording") client.stop();
      else if (client.active) client.cancel();
      else await client.start();
    },
  });
  const command = {
    description: "Pi-owned cotto dictation: on | off | cancel | status",
    handler: async (args: string, ctx: ExtensionContext) => {
      if (ctx.mode !== "tui") return;
      const action = args.trim();
      if (action === "off") {
        // Turning off must work even if the preference cannot be saved.
        disable();
        try {
          writeVoiceEnabled(preferencePath(), false);
          ctx.ui.notify("cotto is off. Saved for future Pi starts and reloads.", "info");
        } catch {
          ctx.ui.notify("cotto is off here, but its preference could not be saved.", "warning");
        }
        return;
      }
      if (action === "cancel") {
        state?.client.cancel();
        return;
      }
      if (action === "status") {
        ctx.ui.notify(
          state
            ? `cotto: ${latestStatus ? labels[latestStatus] : "Ready"}. Ctrl+Shift+R records/stops and requires terminal key-release events; text belongs to the claimed Pi editor, not the active desktop window.`
            : "cotto is off.",
          "info",
        );
        return;
      }
      if (action !== "on") {
        ctx.ui.notify("Use /cotto on, off, cancel, or status.", "info");
        return;
      }
      try {
        writeVoiceEnabled(preferencePath(), true);
      } catch {
        ctx.ui.notify("cotto could not save its preference; activation was not changed.", "error");
        return;
      }
      enable(ctx);
    },
  };
  pi.registerCommand("cotto", command);
  // Retain the old command and storage/status keys without a settings migration.
  pi.registerCommand("sotto", command);
}
