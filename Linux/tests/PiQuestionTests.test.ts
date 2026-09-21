import { expect, test } from "bun:test";
import { questionTarget } from "../integrations/pi/question.ts";

const state = { instance: "question-1", revision: 0, text: "draft", line: 0, col: 5 };
function capability() {
  return {
    id: state.instance,
    available: () => true,
    activate: () => true,
    snapshot: (): unknown => ({ ...state }),
    apply: () => true,
  };
}

test("question capability copies valid snapshots and rejects invalid event shapes", () => {
  expect(questionTarget(undefined)).toBeUndefined();
  expect(questionTarget({ id: "q" })).toBeUndefined();
  const q = questionTarget(capability());
  expect(q?.target.snapshot()).toEqual(state);
  expect(q?.target.snapshot()).not.toBe(state);
});

test("foreign identities, invalid counters and oversized snapshots cannot claim an editor", () => {
  for (const change of [
    { instance: "other" },
    { revision: -1 },
    { revision: Infinity },
    { text: "x".repeat(65537) },
    { line: -1 },
    { col: 0.5 },
  ]) {
    const value = capability();
    value.snapshot = () => ({ ...state, ...change });
    expect(questionTarget(value)?.target.snapshot()).toBeUndefined();
  }
});

test("unavailable, throwing and asynchronous providers fail closed", () => {
  const value = capability();
  value.available = () => false;
  expect(questionTarget(value)?.activate()).toBe(false);
  expect(questionTarget(value)?.target.snapshot()).toBeUndefined();
  value.available = () => {
    throw new Error("disposed");
  };
  expect(questionTarget(value)?.available()).toBe(false);
  value.available = () => true;
  value.snapshot = () => Promise.resolve(state);
  expect(questionTarget(value)?.target.snapshot()).toBeUndefined();
});

test("post-mutation exceptions remain visible to the uncertain-receipt policy", () => {
  const value = capability();
  value.apply = () => {
    throw new Error("after mutation");
  };
  expect(() => questionTarget(value)?.target.apply(state, "text")).toThrow("after mutation");
});
