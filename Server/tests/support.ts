import type { InferenceBackend } from "../src/inference/native-inference.ts";

export class FakeInference implements InferenceBackend {
  async readiness() { return { available: true, message: "Ready.", speechLoaded: true, proofLoaded: true }; }
  async warmUp() {}
  async transcribe(_path: string, _language: string, _terms: string[], progress?: (value: number) => void) {
    progress?.(0.5);
    return { text: "Hello world.", audioSeconds: 1, processingSeconds: 0.01, language: "en", engineVersion: "fixture" };
  }
  async correct(text: string) { return { text, processingSeconds: 0.01, engineVersion: "fixture" }; }
  async cancel() {}
  async shutdown() {}
}
