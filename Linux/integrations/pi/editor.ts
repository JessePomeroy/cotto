import { CustomEditor } from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import { randomUUID } from "node:crypto";

import { sameEditor, type EditorSnapshot } from "./target.ts";

// Preserve CustomEditor's app keybindings; do not replace it with a bare Editor.
export class SottoEditor extends CustomEditor {
  private readonly instance = randomUUID();
  private revision = 0;
  private suspended = false;
  private readonly appKeys: ConstructorParameters<typeof CustomEditor>[2];

  constructor(...args: ConstructorParameters<typeof CustomEditor>) {
    super(...args);
    this.appKeys = args[2];
    let focused = this.focused;
    let onChange = this.onChange;
    // The base class exposes mutable fields, not overridable accessors. Observe
    // their assignments to catch focus leave-and-return and asynchronous edits,
    // while preserving the callbacks installed by Pi after the factory returns.
    Object.defineProperty(this, "focused", {
      configurable: true,
      get: () => focused,
      set: (value: boolean) => {
        if (value !== focused) this.invalidateClaim();
        focused = value;
      },
    });
    Object.defineProperty(this, "onChange", {
      configurable: true,
      get: () => {
        // Capture the current callback: consumers may wrap a previously read
        // onChange. Reading the mutable binding later would recurse into itself.
        const callback = onChange;
        return (text: string) => {
          this.invalidateClaim();
          callback?.(text);
        };
      },
      set: (callback: ((text: string) => void) | undefined) => {
        onChange = callback;
      },
    });
  }

  invalidateClaim(): void {
    this.revision += 1;
  }

  override handleInput(data: string): void {
    this.invalidateClaim();
    // Pi exposes no completion event for an external editor or job suspension.
    // Do not guess when those contexts become safe again; require off/on.
    if (
      this.appKeys.matches(data, "app.editor.external") ||
      this.appKeys.matches(data, "app.suspend")
    )
      this.suspended = true;
    super.handleInput(data);
  }

  override handleMouse(event: TuiMouseEvent) {
    this.invalidateClaim();
    return super.handleMouse(event);
  }

  snapshot(): EditorSnapshot | undefined {
    if (!this.focused || this.suspended) return undefined;
    const text = this.getExpandedText();
    if (Buffer.byteLength(text, "utf8") > 64 * 1024) return undefined;
    const { line, col } = this.getCursor();
    return { instance: this.instance, revision: this.revision, text, line, col };
  }

  apply(expected: EditorSnapshot, text: string): boolean {
    if (!sameEditor(this.snapshot(), expected)) return false;
    // No key events, bracketed-paste parser, submit callback, or await here.
    this.insertTextAtCursor(text);
    this.tui.requestRender();
    return true;
  }
}
