import { NativeInference } from "../../src/inference/native-inference";

const executable = process.argv[2];
const model = process.argv[3];
if (!executable || !model) throw new Error("Missing fixture helper or model.");
const inference = new NativeInference({
  speechHelper: executable, speechModel: model, vadModel: model,
  proofHelper: executable, proofModel: model,
  speechLoadTimeout: 3, proofLoadTimeout: 3,
}, {});
await inference.warmUp();
const request = inference.transcribe(model, "en", []).catch(error => error);
await Bun.sleep(20);
await inference.cancel();
await request;
await inference.warmUp();
await inference.shutdown();
// This is deliberately immediate: a delayed cleanup timer cannot save a helper
// once its parent exits, so shutdown itself must await all three child exits.
process.exit(0);
