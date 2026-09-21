import { afterEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { chmod, mkdtemp, rm } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PiDictation, type DictationStatus } from "../integrations/pi/dictation.ts";
import type { EditorSnapshot } from "../integrations/pi/target.ts";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const close of cleanup.splice(0).reverse()) await close();
});
async function until(check: () => boolean) {
  const end = Date.now() + 2000;
  while (!check()) {
    if (Date.now() > end) throw new Error("Timed out");
    await Bun.sleep(2);
  }
}
async function fixture(hello = true) {
  const directory = await mkdtemp(join(tmpdir(), "sotto-pi-owned-"));
  const path = join(directory, "input.sock");
  const peers = new Set<Socket>();
  const commands: Record<string, unknown>[] = [];
  let peer: Socket | undefined;
  let offeredId = "";
  const send = (message: object) => peer?.write(JSON.stringify(message) + "\n");
  const server = createServer((socket) => {
    peer = socket;
    offeredId = randomUUID();
    peers.add(socket);
    socket.on("error", () => {});
    socket.on("close", () => peers.delete(socket));
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString();
      while (buffer.includes("\n")) {
        const end = buffer.indexOf("\n");
        const message: Record<string, unknown> = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        commands.push(message);
        if (message.op === "start") send({ v: 2, id: message.id, event: "recording" });
        if (message.op === "stop") send({ v: 2, id: message.id, event: "processing" });
      }
    });
    if (hello) send({ v: 2, event: "hello", mode: "pi-owned", id: offeredId });
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  await chmod(path, 0o600);
  const snapshot: EditorSnapshot = {
    instance: "editor",
    revision: 0,
    text: "prefix suffix",
    line: 0,
    col: 7,
  };
  const inserted: string[] = [];
  const statuses: DictationStatus[] = [];
  let available = true;
  let throwAfterEdit = false;
  const client = new PiDictation(
    path,
    {
      snapshot: () => (available ? { ...snapshot } : undefined),
      apply: (_expected, text) => {
        inserted.push(text);
        if (throwAfterEdit) throw new Error("Post-edit callback failed");
        return true;
      },
    },
    (status) => statuses.push(status),
  );
  cleanup.push(async () => {
    client.cancel();
    for (const socket of peers) socket.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  });
  return {
    client,
    commands,
    inserted,
    statuses,
    snapshot,
    path,
    send,
    get peer() {
      return peer;
    },
    get offeredId() {
      return offeredId;
    },
    get id() {
      return commands.find((message) => message.op === "start")?.id;
    },
    unavailable: () => {
      available = false;
    },
    throwAfterEdit: () => {
      throwAfterEdit = true;
    },
    async recording() {
      await client.start();
      await until(() => client.phase === "recording");
    },
  };
}

test("literal Unicode insertion, receipt, no replay", async () => {
  const f = await fixture();
  await f.recording();
  f.client.stop();
  await until(() => f.commands.some((message) => message.op === "stop"));
  const result = { v: 2, id: f.id, event: "transcript", text: "café 世界" };
  expect(f.id).toBe(f.offeredId);
  expect(f.commands[0]?.v).toBe(2);
  f.peer?.write(JSON.stringify(result) + "\n" + JSON.stringify(result) + "\n");
  await until(() => f.commands.some((message) => message.op === "receipt"));
  expect(f.inserted).toEqual(["café 世界"]);
  expect(f.commands.at(-1)?.status).toBe("inserted");
  expect(f.client.active).toBe(false);
});

test.each(["cursor", "text", "revision", "instance", "unavailable"])(
  "changed %s blocks delivery",
  async (kind) => {
    const f = await fixture();
    await f.recording();
    f.client.stop();
    if (kind === "cursor") f.snapshot.col++;
    if (kind === "text") f.snapshot.text += "edited";
    if (kind === "revision") f.snapshot.revision++;
    if (kind === "instance") f.snapshot.instance = "replacement";
    if (kind === "unavailable") f.unavailable();
    f.send({ v: 2, id: f.id, event: "transcript", text: "late text" });
    await until(() => f.commands.some((message) => message.op === "receipt"));
    expect(f.inserted).toEqual([]);
    expect(f.commands.at(-1)?.status).toBe("blocked");
  },
);

test("Sotto UI stop moves the owner into processing", async () => {
  const f = await fixture();
  await f.recording();
  f.send({ v: 2, id: f.id, event: "processing" });
  await until(() => f.client.phase === "processing");
  f.send({ v: 2, id: f.id, event: "transcript", text: "UI stopped take" });
  await until(() => !f.client.active);
  expect(f.inserted).toEqual(["UI stopped take"]);
});

test("cancel while connecting creates no late socket", async () => {
  const f = await fixture();
  const start = f.client.start();
  f.client.cancel();
  await start;
  await Bun.sleep(20);
  expect(f.peer).toBeUndefined();
  expect(f.inserted).toEqual([]);
});

test("changed editor before handshake does not start microphone", async () => {
  const f = await fixture(false);
  await f.client.start();
  await until(() => !!f.peer);
  f.snapshot.revision++;
  f.send({ v: 2, event: "hello", mode: "pi-owned", id: f.offeredId });
  await until(() => !f.client.active);
  expect(f.commands).toEqual([]);
});

test("cancel during transcription ignores late result", async () => {
  const f = await fixture();
  await f.recording();
  f.client.stop();
  f.client.cancel();
  f.send({ v: 2, id: f.id, event: "transcript", text: "late text" });
  await until(() => f.commands.some((message) => message.op === "cancel"));
  expect(f.inserted).toEqual([]);
  expect(f.client.active).toBe(false);
});

test("an editor changed before stop cancels rather than delivers", async () => {
  const f = await fixture();
  await f.recording();
  f.snapshot.revision++;
  f.client.stop();
  await until(() => f.commands.some((message) => message.op === "cancel"));
  expect(f.commands.some((message) => message.op === "stop")).toBe(false);
});

test("exception after mutation reports uncertain without retry", async () => {
  const f = await fixture();
  await f.recording();
  f.throwAfterEdit();
  f.send({ v: 2, id: f.id, event: "transcript", text: "one insertion" });
  await until(() => f.commands.some((message) => message.op === "receipt"));
  expect(f.inserted).toEqual(["one insertion"]);
  expect(f.commands.at(-1)?.status).toBe("uncertain");
});

test.each(["", " \t", "one\ntwo", "\u001b[201~", "\u202e", "\u2028", "\ud800", "x".repeat(65537)])(
  "rejects unsafe text %#",
  async (text) => {
    const f = await fixture();
    await f.recording();
    f.send({ v: 2, id: f.id, event: "transcript", text });
    await until(() => !f.client.active);
    expect(f.inserted).toEqual([]);
    expect(f.statuses.at(-1)).toBe("blocked");
  },
);

test.each(["wrong-id", "wrong-version", "extra-field", "bad-utf8", "oversized"])(
  "rejects %s response",
  async (kind) => {
    const f = await fixture();
    await f.recording();
    if (kind === "bad-utf8") f.peer?.write(Buffer.from([0xff, 10]));
    else if (kind === "oversized") f.peer?.write(Buffer.alloc(256 * 1024 + 1, 120));
    else
      f.send({
        v: kind === "wrong-version" ? 1 : 2,
        id: kind === "wrong-id" ? "other" : f.id,
        event: "transcript",
        text: "do not insert",
        ...(kind === "extra-field" ? { extra: true } : {}),
      });
    await until(() => !f.client.active);
    expect(f.inserted).toEqual([]);
  },
);

test.each(["legacy", "missing-id", "invalid-id", "extra-field"])(
  "rejects %s handshake before capture",
  async (kind) => {
    const f = await fixture(false);
    await f.client.start();
    await until(() => !!f.peer);
    f.send({
      v: kind === "legacy" ? 1 : 2,
      event: "hello",
      mode: "pi-owned",
      ...(kind === "missing-id" ? {} : { id: kind === "invalid-id" ? "not-a-uuid" : f.offeredId }),
      ...(kind === "extra-field" ? { extra: true } : {}),
    });
    await until(() => !f.client.active);
    expect(f.commands).toEqual([]);
    expect(f.inserted).toEqual([]);
  },
);

test("refuses a public socket", async () => {
  const f = await fixture();
  await chmod(f.path, 0o666);
  await f.client.start();
  expect(f.client.active).toBe(false);
  expect(f.peer).toBeUndefined();
});

test("disconnect cannot move the result to a new take", async () => {
  const f = await fixture();
  await f.recording();
  const old = f.id;
  f.peer?.destroy();
  await until(() => !f.client.active);
  f.commands.splice(0);
  await f.recording();
  expect(f.id).not.toBe(old);
  f.send({ v: 2, id: old, event: "transcript", text: "stale" });
  await until(() => !f.client.active);
  expect(f.inserted).toEqual([]);
});
