import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import openapiTS, { astToString } from "openapi-typescript";
import { format, resolveConfig } from "prettier";
import { parse } from "yaml";

const options = new Set(process.argv.slice(2));
for (const option of options) {
  if (option !== "--check") throw new Error(`Unknown API generation option: ${option}`);
}
const schemaPath = resolve(import.meta.dir, "../api/openapi.yaml");
const output = resolve(import.meta.dir, "../src/generated/api.ts");
const document = parse(await readFile(schemaPath, "utf8"));
const source = astToString(await openapiTS(document, { defaultNonNullable: false }));
const formatted = await format(source, { ...(await resolveConfig(output)), filepath: output });
if (options.has("--check")) {
  if ((await readFile(output, "utf8")) !== formatted)
    throw new Error(`Generated API bindings are stale: ${output}`);
  console.log("API bindings match the contract.");
} else {
  await writeFile(output, formatted);
  console.log("Generated TypeScript API bindings.");
}
