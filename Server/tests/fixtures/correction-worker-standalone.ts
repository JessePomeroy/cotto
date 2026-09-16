import { strict as assert } from "node:assert";
import { evaluateCorrection } from "../../src/domain/correction.ts";
import { evaluateCorrectionInWorker } from "../../src/domain/correction-runtime.ts";

assert.equal(Bun.isStandaloneExecutable, true);
for (const [original, candidate, preferredTerms] of [
  ["Hello world.", "Hello world.", []],
  ["I use Type Script at the café.", "I use TypeScript at the café.", ["TypeScript"]],
] satisfies [string, string, string[]][]) {
  assert.deepEqual(
    await evaluateCorrectionInWorker(original, candidate, preferredTerms),
    evaluateCorrection(original, candidate, preferredTerms),
  );
}
console.log("Compiled correction worker parity passed.");
