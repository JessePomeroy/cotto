import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readVoiceEnabled, writeVoiceEnabled } from "../integrations/pi/preferences.ts";

const roots: string[] = [];
const fixture = () => {
  const root = mkdtempSync(join(tmpdir(), "sotto-preference-"));
  roots.push(root);
  return { root, path: join(root, "sotto-voice.json") };
};
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("Pi voice preference", () => {
  test("defaults on without creating configuration", () => {
    const { root, path } = fixture();
    expect(readVoiceEnabled(path)).toBe(true);
    expect(readdirSync(root)).toEqual([]);
  });

  test("remembers off and explicit re-enable in a private complete file", () => {
    const { root, path } = fixture();
    writeVoiceEnabled(path, false);
    expect(readVoiceEnabled(path)).toBe(false);
    expect(JSON.parse(readFileSync(path, "utf8"))).toEqual({ enabled: false });
    expect(statSync(path).mode & 0o777).toBe(0o600);
    writeVoiceEnabled(path, true);
    expect(readVoiceEnabled(path)).toBe(true);
    expect(readdirSync(root)).toEqual(["sotto-voice.json"]);
  });

  test.each(["{", "null", "[]", "{}", '{"enabled":"false"}', '{"enabled":true,"unknown":1}'])(
    "does not silently enable for invalid preference %s",
    (contents) => {
      const { path } = fixture();
      writeFileSync(path, contents);
      expect(() => readVoiceEnabled(path)).toThrow();
      expect(readFileSync(path, "utf8")).toBe(contents);
    },
  );

  test("fails closed on I/O errors and cleans up an unsuccessful replacement", () => {
    const { root, path } = fixture();
    mkdirSync(path);
    expect(() => readVoiceEnabled(path)).toThrow();
    expect(() => writeVoiceEnabled(path, false)).toThrow();
    expect(statSync(path).isDirectory()).toBe(true);
    expect(readdirSync(root)).toEqual(["sotto-voice.json"]);
  });
});
