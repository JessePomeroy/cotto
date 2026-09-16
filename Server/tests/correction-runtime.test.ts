import { expect, test } from 'bun:test';
import { evaluateCorrectionInWorker } from '../src/domain/correction-runtime.ts';
import { evaluateCorrection } from '../src/domain/correction.ts';

test('worker returns the deterministic correction policy result', async () => {
  const original = 'I want orange, erm, yellow.', candidate = 'I want yellow.';
  expect(await evaluateCorrectionInWorker(original, candidate, ['Codex'])).toEqual(evaluateCorrection(original, candidate, ['Codex']));
});
test('cancellation terminates outstanding worker evaluation', async () => {
  const controller = new AbortController(); const evaluation = evaluateCorrectionInWorker('one '.repeat(1000), 'two '.repeat(1000), [], controller.signal); controller.abort();
  await expect(evaluation).rejects.toThrow('Recording cancelled.');
});
