import { evaluateCorrection } from './correction.ts';

self.onmessage = (event: MessageEvent<{ original: string; candidate: string; preferredTerms: string[] }>) => {
  const { original, candidate, preferredTerms } = event.data;
  self.postMessage(evaluateCorrection(original, candidate, preferredTerms));
};
