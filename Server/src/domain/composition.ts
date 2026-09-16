import type { DictationContinuation } from "../api.ts";
import type { FormattedDictation } from "./lists.ts";

const trim = (text: string) =>
  text.replace(/^[\p{White_Space}\u200B]+|[\p{White_Space}\u200B]+$/gu, "");

export function composeDictation(formatted: FormattedDictation, previous?: DictationContinuation) {
  const body = trim(formatted.text);
  if (body.length === 0) {
    if (!formatted.isControlOnly)
      return { insertion: "", preview: previous?.preview ?? "", continuation: previous };
    if (formatted.endedList && formatted.context === undefined) {
      const preview = previous?.preview ?? "";
      const needsParagraph = preview.length > 0 || previous?.boundary === "paragraph";
      const continuation: DictationContinuation | undefined = needsParagraph
        ? { preview, boundary: "paragraph" }
        : undefined;
      return { insertion: "", preview, continuation };
    }
    const carried = formatted.continuesPreviousList ? previous : undefined;
    const preview = carried?.preview ?? "";
    const needsParagraph =
      previous?.boundary === "paragraph" || (previous !== undefined && previous.preview.length > 0);
    const boundary = carried?.boundary ?? (needsParagraph ? "paragraph" : "none");
    const continuation: DictationContinuation = { list: formatted.context, preview, boundary };
    return { insertion: "", preview, continuation };
  }
  const continuing = formatted.continuesPreviousList && previous !== undefined;
  let separator = "";
  if (previous !== undefined) {
    if (continuing)
      separator =
        previous.boundary === "paragraph" ? "\n\n" : previous.boundary === "line" ? "\n" : "";
    else if (
      previous.boundary === "paragraph" ||
      previous.list !== undefined ||
      (previous.preview.length > 0 && (formatted.containsList || formatted.context !== undefined))
    )
      separator = "\n\n";
  }
  const finishingPreviousList = formatted.endedList && previous?.list !== undefined;
  const keepPreview =
    continuing ||
    ((previous?.boundary === "paragraph" || finishingPreviousList) && !formatted.containsList);
  const preview =
    keepPreview && previous !== undefined && previous.preview.length > 0
      ? previous.preview + separator + body
      : body;
  const suffix = formatted.endsWithList || formatted.context !== undefined ? "" : " ";
  const boundary =
    formatted.context !== undefined ? "line" : formatted.endsWithList ? "paragraph" : "none";
  const continuation: DictationContinuation = { list: formatted.context, preview, boundary };
  return { insertion: separator + body + suffix, preview, continuation };
}

/** Continuations commit only after delivery; retain Swift's bounded expiration. */
export class DictationContinuationMemory<Anchor> {
  private entries: { anchor: Anchor; continuation: DictationContinuation; timestamp: number }[] =
    [];
  private readonly lifetime: number;
  private readonly capacity: number;

  constructor(lifetime = 15 * 60, capacity = 8) {
    this.lifetime = Math.max(0, lifetime);
    this.capacity = Math.max(1, capacity);
  }

  continuation(anchor: Anchor, now: number) {
    this.expire(now);
    return this.entries.findLast((entry) => entry.anchor === anchor)?.continuation;
  }

  remember(continuation: DictationContinuation | undefined, anchor: Anchor, now: number) {
    this.expire(now);
    this.forget(anchor);
    if (continuation === undefined) return;
    this.entries.push({ anchor, continuation, timestamp: now });
    if (this.entries.length > this.capacity)
      this.entries.splice(0, this.entries.length - this.capacity);
  }

  forget(anchor: Anchor) {
    this.entries = this.entries.filter((entry) => entry.anchor !== anchor);
  }
  removeAll() {
    this.entries = [];
  }
  private expire(now: number) {
    this.entries = this.entries.filter(
      (entry) => now >= entry.timestamp && now - entry.timestamp < this.lifetime,
    );
  }
}
