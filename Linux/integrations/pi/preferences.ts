import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export function readVoiceEnabled(path: string): boolean {
  let contents: string;
  try {
    contents = readFileSync(path, "utf8");
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return true;
    throw error;
  }
  const value: unknown = JSON.parse(contents);
  if (
    typeof value !== "object" ||
    value === null ||
    !("enabled" in value) ||
    typeof value.enabled !== "boolean" ||
    Object.keys(value).length !== 1
  ) {
    throw new Error("Invalid cotto voice preference");
  }
  return value.enabled;
}

export function writeVoiceEnabled(path: string, enabled: boolean): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify({ enabled })}\n`, { flag: "wx", mode: 0o600 });
  try {
    // Other Pi processes must never observe a partially written preference.
    renameSync(temporary, path);
  } catch (error) {
    unlinkSync(temporary);
    throw error;
  }
}
