import { dlopen } from "bun:ffi";
import { closeSync, constants, fstatSync, mkdirSync, openSync } from "node:fs";
import { join } from "node:path";

// Keep one stable inode for the advisory lock. A PID file cannot protect an
// archive from concurrent processes or recover reliably after a crash.
export function acquireDataDirectoryLock(directory: string) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (process.platform !== "linux") throw new Error("The cotto server requires Linux.");
  const library = dlopen("libc.so.6", {
    flock: { args: ["i32", "i32"], returns: "i32" },
  });
  let descriptor: number | undefined;
  try {
    descriptor = openSync(
      join(directory, ".server.lock"),
      constants.O_RDWR | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      0o600,
    );
    if (!fstatSync(descriptor).isFile()) {
      throw new Error("The server data directory lock must be a regular file.");
    }
    if (library.symbols.flock(descriptor, 2 | 4) !== 0) {
      throw new Error(
        "Another Sotto server is already using this data directory, or its lock could not be acquired. Stop that runner or choose a different --data-dir.",
      );
    }
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    library.close();
    throw error;
  }

  return {
    release() {
      if (descriptor === undefined) return;
      const opened = descriptor;
      descriptor = undefined;
      // Closing the descriptor releases flock even after a process crash. Never
      // unlink .server.lock: another runner could then lock a different inode.
      closeSync(opened);
      library.close();
    },
  };
}
