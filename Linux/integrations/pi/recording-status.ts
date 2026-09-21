import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { dirname } from "node:path";

export async function readRecordingStatus(path: string, now?: number): Promise<boolean> {
  try {
    const uid = process.getuid?.();
    const directory = await lstat(dirname(path));
    if (
      uid === undefined ||
      !directory.isDirectory() ||
      directory.uid !== uid ||
      directory.mode & 0o077
    )
      return false;
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = await file.stat();
      if (!info.isFile() || info.uid !== uid || info.mode & 0o077 || info.size > 256) return false;
      const bytes = Buffer.alloc(257);
      const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
      if (bytesRead > 256) return false;
      const value: unknown = JSON.parse(bytes.subarray(0, bytesRead).toString("utf8"));
      if (
        value === null ||
        typeof value !== "object" ||
        !("v" in value) ||
        value.v !== 1 ||
        !("recording" in value) ||
        typeof value.recording !== "boolean" ||
        !("updatedAt" in value) ||
        typeof value.updatedAt !== "number" ||
        !Number.isSafeInteger(value.updatedAt) ||
        Object.keys(value).length !== 3
      )
        return false;
      const age = (now ?? Date.now()) - value.updatedAt;
      return value.recording && age >= 0 && age < 2500;
    } finally {
      await file.close();
    }
  } catch {
    return false;
  }
}

// One read in flight, bounded input, no command channel, no transcript access.
export function observeRecording(path: string, changed: (recording: boolean) => void): () => void {
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let previous: boolean | undefined;
  const poll = async () => {
    const recording = await readRecordingStatus(path);
    if (stopped) return;
    if (recording !== previous) {
      previous = recording;
      changed(recording);
    }
    timer = setTimeout(() => void poll(), 250);
    timer.unref();
  };
  void poll();
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}
