import { createHash } from "node:crypto";
import { constants, type BigIntStats } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { basename } from "node:path";
import { checkCancellation, InferenceError } from "./inference-error";

export interface ModelPin {
  bytes?: number;
  sha256: string;
}

function fingerprint(info: BigIntStats) {
  return [info.dev, info.ino, info.size, info.mtimeNs, info.ctimeNs].join(":");
}

function pinKey(pin: ModelPin) {
  return `${pin.bytes ?? ""}:${pin.sha256}`;
}

async function pathFingerprint(path: string) {
  const info = await lstat(path, { bigint: true });
  if (!info.isFile())
    throw new InferenceError(
      "unavailable",
      `The inference model must be a readable regular file: ${basename(path)}`,
    );
  return fingerprint(info);
}

/** Hashes in bounded chunks; caches bind to inode, size and nanosecond timestamps. */
export class ModelVerifier {
  private verified = new Map<string, { pin: string; fingerprint: string }>();
  private generation = 0;
  private readonly hashes = new Set<Promise<unknown>>();
  private pending = new Map<
    string,
    {
      pin: string;
      controller: AbortController;
      task: Promise<{ pin: string; fingerprint: string }>;
      waiters: number;
    }
  >();

  async isVerified(path: string, pin?: ModelPin) {
    if (!pin) return true;
    const entry = this.verified.get(path);
    if (!entry || entry.pin !== pinKey(pin)) return false;
    try {
      return entry.fingerprint === (await pathFingerprint(path));
    } catch {
      return false;
    }
  }

  async verify(path: string, pin?: ModelPin, signal?: AbortSignal) {
    checkCancellation(signal);
    if (!pin) return undefined;
    const generation = this.generation;
    const verified = await this.isVerified(path, pin);
    checkCancellation(signal);
    if (generation !== this.generation) throw new InferenceError("cancelled");
    if (verified) return pin.sha256;
    this.verified.delete(path);
    let operation = this.pending.get(path);
    if (operation?.controller.signal.aborted) {
      this.pending.delete(path);
      operation = undefined;
    }
    if (!operation) {
      const controller = new AbortController();
      operation = {
        pin: pinKey(pin),
        controller,
        task: this.hash(path, pin, controller.signal),
        waiters: 0,
      };
      this.pending.set(path, operation);
      const started = operation;
      const task = started.task;
      this.hashes.add(task);
      void task
        .finally(() => {
          this.hashes.delete(task);
          if (this.pending.get(path) === started) this.pending.delete(path);
        })
        .catch(() => {});
    }
    const pending = operation;
    if (pending.pin !== pinKey(pin))
      throw new InferenceError("unavailable", "Model verification configuration changed.");
    ++pending.waiters;
    let cancel: (() => void) | undefined;
    try {
      const result = await new Promise<Awaited<typeof pending.task>>((resolve, reject) => {
        // A caller owns only its wait. Other consumers retain the shared hash.
        cancel = () => reject(new InferenceError("cancelled"));
        signal?.addEventListener("abort", cancel, { once: true });
        pending.controller.signal.addEventListener("abort", cancel, { once: true });
        if (signal?.aborted || pending.controller.signal.aborted) cancel();
        pending.task.then(resolve, reject);
      });
      checkCancellation(signal);
      checkCancellation(pending.controller.signal);
      if (generation !== this.generation) throw new InferenceError("cancelled");
      if (result.pin !== pinKey(pin))
        throw new InferenceError("unavailable", "Model verification configuration changed.");
      this.verified.set(path, result);
      return pin.sha256;
    } finally {
      if (cancel) {
        signal?.removeEventListener("abort", cancel);
        pending.controller.signal.removeEventListener("abort", cancel);
      }
      --pending.waiters;
      if (pending.waiters === 0 && this.pending.get(path) === pending) {
        // Retire immediately so a new request cannot join an aborted operation.
        this.pending.delete(path);
        pending.controller.abort();
      }
    }
  }

  cancel() {
    ++this.generation;
    for (const operation of this.pending.values()) operation.controller.abort();
    this.pending.clear();
  }

  async shutdown() {
    const tasks = [...this.hashes];
    this.cancel();
    // Hash tasks close their descriptors in finally before shutdown resolves.
    await Promise.allSettled(tasks);
  }

  private async hash(path: string, pin: ModelPin, signal: AbortSignal) {
    let handle;
    try {
      handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      checkCancellation(signal);
      const info = await handle.stat({ bigint: true });
      if (!info.isFile())
        throw new InferenceError("unavailable", "The inference model must be a regular file.");
      const before = fingerprint(info);
      if (pin.bytes !== undefined && info.size !== BigInt(pin.bytes)) {
        throw new InferenceError(
          "unavailable",
          `The ${basename(path)} model has an incorrect size; install the pinned model.`,
        );
      }
      const digest = createHash("sha256");
      const buffer = Buffer.allocUnsafe(4 * 1024 * 1024);
      let total = 0n;
      while (true) {
        checkCancellation(signal);
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
        checkCancellation(signal);
        if (bytesRead === 0) break;
        total += BigInt(bytesRead);
        if (total > info.size)
          throw new InferenceError(
            "unavailable",
            "The model changed during integrity verification.",
          );
        digest.update(buffer.subarray(0, bytesRead));
      }
      const after = await handle.stat({ bigint: true });
      if (
        total !== info.size ||
        fingerprint(after) !== before ||
        (await pathFingerprint(path)) !== before
      ) {
        throw new InferenceError("unavailable", "The model changed during integrity verification.");
      }
      checkCancellation(signal);
      if (digest.digest("hex") !== pin.sha256) {
        throw new InferenceError(
          "unavailable",
          `The ${basename(path)} model failed SHA-256 verification; install the pinned model.`,
        );
      }
      return { pin: pinKey(pin), fingerprint: before };
    } catch (error) {
      if (error instanceof InferenceError) throw error;
      throw new InferenceError("unavailable", `Could not read inference model: ${basename(path)}`);
    } finally {
      await handle?.close();
    }
  }
}
