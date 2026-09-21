import { lstat } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
import { dirname, isAbsolute } from "node:path";
import { sameEditor, type EditorSnapshot, type InputTarget } from "./target.ts";

type Phase = "connecting" | "starting" | "recording" | "processing";
export type DictationStatus = Phase | "inserted" | "blocked" | "uncertain" | "cancelled";
type Take = {
  id: string;
  expected: EditorSnapshot;
  phase: Phase;
  socket?: Socket;
  buffer: Buffer;
  timer: ReturnType<typeof setTimeout>;
  expiresAt: number;
};

// The initiating Pi editor owns the take. This never routes to whichever app
// happens to be focused when ASR finishes, and makes no desktop-focus claim.
export class PiDictation {
  private take?: Take;
  constructor(
    private readonly path: string,
    private readonly target: InputTarget,
    private readonly changed: (status: DictationStatus) => void,
  ) {}

  get active(): boolean {
    return this.take !== undefined;
  }
  get phase(): Phase | undefined {
    return this.take?.phase;
  }

  async start(): Promise<void> {
    if (this.take) return;
    const expected = this.target.snapshot();
    if (!expected) {
      this.changed("blocked");
      return;
    }
    const take: Take = {
      id: "",
      expected,
      phase: "connecting",
      buffer: Buffer.alloc(0),
      timer: setTimeout(() => this.fail(take), 15000),
      expiresAt: performance.now() + 15000,
    };
    this.take = take;
    this.changed("connecting");
    try {
      const uid = process.getuid?.();
      if (uid === undefined || !isAbsolute(this.path) || Buffer.byteLength(this.path) > 103)
        throw new Error("Invalid socket path");
      const [directory, endpoint] = await Promise.all([
        lstat(dirname(this.path)),
        lstat(this.path),
      ]);
      if (
        !directory.isDirectory() ||
        directory.isSymbolicLink() ||
        directory.uid !== uid ||
        (directory.mode & 0o077) !== 0 ||
        !endpoint.isSocket() ||
        endpoint.uid !== uid ||
        (endpoint.mode & 0o077) !== 0
      )
        throw new Error("Untrusted endpoint");
      if (this.take !== take) return;
      if (!sameEditor(this.target.snapshot(), expected)) {
        this.fail(take);
        return;
      }
      const socket = createConnection(this.path);
      take.socket = socket;
      socket.on("error", () => this.fail(take));
      socket.on("close", () => this.fail(take));
      socket.on("data", (data: Buffer) => this.receive(take, data));
    } catch {
      this.fail(take);
    }
  }

  stop(): void {
    const take = this.take;
    if (!take || take.phase !== "recording") return;
    if (performance.now() >= take.expiresAt || !sameEditor(this.target.snapshot(), take.expected)) {
      this.cancel();
      return;
    }
    take.phase = "processing";
    this.deadline(take, 120000);
    take.socket?.write(this.frame(take, "stop"));
    this.changed("processing");
  }

  cancel(): void {
    const take = this.take;
    if (!take) return;
    this.take = undefined;
    clearTimeout(take.timer);
    if (take.phase === "connecting") take.socket?.destroy();
    else this.finishSocket(take, this.frame(take, "cancel"));
    this.changed("cancelled");
  }

  private frame(take: Take, op: string, status?: string): string {
    return (
      JSON.stringify({
        v: 2,
        id: take.id,
        op,
        ...(status ? { status } : {}),
      }) + "\n"
    );
  }
  private finishSocket(take: Take, frame: string): void {
    take.socket?.setTimeout(1000, () => take.socket?.destroy());
    take.socket?.end(frame);
  }
  private deadline(take: Take, ms: number): void {
    clearTimeout(take.timer);
    take.expiresAt = performance.now() + ms;
    take.timer = setTimeout(() => this.fail(take), ms);
  }
  private fail(take: Take): void {
    if (this.take !== take) return;
    this.take = undefined;
    clearTimeout(take.timer);
    take.socket?.destroy();
    this.changed("blocked");
  }

  private receive(take: Take, data: Buffer): void {
    if (this.take !== take) return;
    if (performance.now() >= take.expiresAt) {
      this.fail(take);
      return;
    }
    if (take.buffer.length + data.length > 256 * 1024) {
      this.fail(take);
      return;
    }
    take.buffer = Buffer.concat([take.buffer, data]);
    let frames = 0;
    while (this.take === take) {
      const end = take.buffer.indexOf(10);
      if (end < 0) return;
      if (++frames > 16) {
        this.fail(take);
        return;
      }
      const line = take.buffer.subarray(0, end);
      take.buffer = take.buffer.subarray(end + 1);
      try {
        const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line));
        if (!value || typeof value !== "object" || Array.isArray(value))
          throw new Error("Invalid frame");
        const message = value as Record<string, unknown>;
        if (message.v !== 2) throw new Error("Invalid version; reload Pi after updating cotto");
        if (
          message.event === "hello" &&
          take.phase === "connecting" &&
          message.mode === "pi-owned" &&
          typeof message.id === "string" &&
          /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
            message.id,
          ) &&
          Object.keys(message).length === 4
        ) {
          if (!sameEditor(this.target.snapshot(), take.expected)) throw new Error("Changed editor");
          // The bridge issues exactly one ID for this connection. Replays on
          // either this socket or a later connection cannot admit another take.
          take.id = message.id;
          take.phase = "starting";
          take.socket?.write(this.frame(take, "start"));
          this.changed("starting");
        } else if (message.id !== take.id) throw new Error("Wrong take");
        else if (
          message.event === "recording" &&
          take.phase === "starting" &&
          Object.keys(message).length === 3
        ) {
          take.phase = "recording";
          this.deadline(take, 240000);
          this.changed("recording");
        } else if (
          message.event === "processing" &&
          (take.phase === "processing" || take.phase === "recording") &&
          Object.keys(message).length === 3
        ) {
          // Sotto's own Stop button may finish an explicitly Pi-owned take too.
          if (take.phase === "recording") {
            take.phase = "processing";
            this.deadline(take, 120000);
            this.changed("processing");
          }
        } else if (
          message.event === "transcript" &&
          (take.phase === "processing" || take.phase === "recording") &&
          typeof message.text === "string" &&
          Object.keys(message).length === 4
        ) {
          this.deliver(take, message.text);
        } else throw new Error("Unexpected response");
      } catch {
        this.fail(take);
        return;
      }
    }
  }

  private deliver(take: Take, text: string): void {
    // Consume before touching the editor. A callback/exception or missing receipt
    // must never turn this take into an automatically retried insertion.
    this.take = undefined;
    clearTimeout(take.timer);
    let status: "inserted" | "blocked" | "uncertain" = "blocked";
    try {
      const safe =
        text.trim().length > 0 &&
        Buffer.byteLength(text) <= 64 * 1024 &&
        !/[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/u.test(text);
      if (
        safe &&
        sameEditor(this.target.snapshot(), take.expected) &&
        this.target.apply(take.expected, text)
      )
        status = "inserted";
    } catch {
      status = "uncertain";
    }
    this.finishSocket(take, this.frame(take, "receipt", status));
    this.changed(status);
  }
}
