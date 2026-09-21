import type { EditorSnapshot, InputTarget } from "./target.ts";

export interface QuestionTarget {
  id: string;
  available(): boolean;
  activate(): boolean;
  target: InputTarget;
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function snapshot(value: unknown, id: string): EditorSnapshot | undefined {
  if (
    !record(value) ||
    value.instance !== id ||
    typeof value.revision !== "number" ||
    !Number.isSafeInteger(value.revision) ||
    value.revision < 0 ||
    typeof value.text !== "string" ||
    Buffer.byteLength(value.text) > 64 * 1024 ||
    typeof value.line !== "number" ||
    !Number.isSafeInteger(value.line) ||
    value.line < 0 ||
    typeof value.col !== "number" ||
    !Number.isSafeInteger(value.col) ||
    value.col < 0
  )
    return undefined;
  return {
    instance: id,
    revision: value.revision,
    text: value.text,
    line: value.line,
    col: value.col,
  };
}

// Optional, in-process cooperation with ask_user. No terminal injection and no
// dependency on that extension's installation path. Treat event payloads as unknown.
export function questionTarget(value: unknown): QuestionTarget | undefined {
  if (!record(value) || typeof value.id !== "string" || !/^[\w-]{1,128}$/.test(value.id)) return;
  const { id, available, activate, snapshot: read, apply } = value;
  if (
    typeof available !== "function" ||
    typeof activate !== "function" ||
    typeof read !== "function" ||
    typeof apply !== "function"
  )
    return;
  const isAvailable = () => {
    try {
      return available() === true;
    } catch {
      return false;
    }
  };
  return {
    id,
    available: isAvailable,
    activate: () => {
      try {
        return isAvailable() && activate() === true;
      } catch {
        return false;
      }
    },
    target: {
      snapshot: () => {
        try {
          return isAvailable() ? snapshot(read(), id) : undefined;
        } catch {
          return undefined;
        }
      },
      // Do not swallow a post-mutation exception: PiDictation must report uncertain.
      apply: (expected, text) => isAvailable() && apply(expected, text) === true,
    },
  };
}
