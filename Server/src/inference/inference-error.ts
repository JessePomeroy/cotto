export type InferenceErrorCode = "unavailable" | "invalidRequest" | "invalidResponse" | "timeout" | "cancelled" | "busy";

export class InferenceError extends Error {
  constructor(readonly code: InferenceErrorCode, message = code === "cancelled"
    ? "Inference cancelled."
    : "The inference engine is already processing a request.") {
    super(message);
    this.name = "InferenceError";
  }
}

export function checkCancellation(signal?: AbortSignal) {
  if (signal?.aborted) throw new InferenceError("cancelled");
}
