import { expect, test } from "bun:test";
import { chmod, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { readRecordingStatus, observeRecording } from "../integrations/pi/recording-status.ts";

test("recording indicator rejects expired, oversized, public, and linked status files", async () => {
  const root = await mkdtemp("/tmp/cotto-indicator-");
  const path = join(root, "recording.json");
  try {
    expect(await readRecordingStatus(path)).toBe(false);
    await writeFile(path, JSON.stringify({ v: 1, recording: true, updatedAt: 1000 }), {
      mode: 0o600,
    });
    expect(await readRecordingStatus(path, 1500)).toBe(true);
    expect(await readRecordingStatus(path, 3500)).toBe(false);
    expect(await readRecordingStatus(path, 999)).toBe(false);
    await chmod(path, 0o644);
    expect(await readRecordingStatus(path, 1500)).toBe(false);
    await chmod(path, 0o600);
    const link = join(root, "link.json");
    await symlink(path, link);
    expect(await readRecordingStatus(link, 1500)).toBe(false);
    await writeFile(path, "x".repeat(300));
    expect(await readRecordingStatus(path)).toBe(false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("observer reports recording changes and cannot update after cleanup", async () => {
  const root = await mkdtemp("/tmp/cotto-observer-");
  const path = join(root, "recording.json");
  const states: boolean[] = [];
  const stop = observeRecording(path, (recording) => states.push(recording));
  try {
    await Bun.sleep(30);
    expect(states).toEqual([false]);
    await writeFile(path, JSON.stringify({ v: 1, recording: true, updatedAt: Date.now() }), {
      mode: 0o600,
    });
    await Bun.sleep(300);
    expect(states).toEqual([false, true]);
    stop();
    await writeFile(path, JSON.stringify({ v: 1, recording: false, updatedAt: Date.now() }));
    await Bun.sleep(300);
    expect(states).toEqual([false, true]);
  } finally {
    stop();
    await rm(root, { recursive: true, force: true });
  }
});
