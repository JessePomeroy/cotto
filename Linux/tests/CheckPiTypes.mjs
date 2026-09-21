#!/usr/bin/env node
// Uses this repository's compiler and an explicitly supplied Pi installation.
// No package installation, user configuration, or live Pi session is involved.
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

if (!process.argv[2])
  throw new Error("Usage: node Linux/tests/CheckPiTypes.mjs /path/to/pi-coding-agent");
const host = resolve(process.argv[2]);
const root = fileURLToPath(new URL("../../", import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), "sotto-pi-types-"));
try {
  const config = join(temporary, "tsconfig.json");
  await writeFile(
    config,
    JSON.stringify({
      compilerOptions: {
        strict: true,
        noEmit: true,
        target: "ES2023",
        module: "ESNext",
        moduleResolution: "Bundler",
        allowImportingTsExtensions: true,
        skipLibCheck: true,
        types: ["bun"],
        typeRoots: [join(root, "Server/node_modules/@types")],
        paths: {
          "@earendil-works/pi-coding-agent": [join(host, "dist/index.d.ts")],
          "@earendil-works/pi-tui": [
            join(host, "node_modules/@earendil-works/pi-tui/dist/index.d.ts"),
          ],
        },
      },
      files: [
        join(root, "Linux/integrations/pi/voice.ts"),
        join(root, "Linux/tests/PiDictationTests.test.ts"),
        join(root, "Linux/tests/PiPreferencesTests.test.ts"),
        join(root, "Linux/tests/PiQuestionTests.test.ts"),
        join(root, "Linux/tests/RecordingStatusTests.test.ts"),
      ],
    }),
  );
  execFileSync(join(root, "Server/node_modules/.bin/tsc"), ["-p", config], {
    stdio: "inherit",
    cwd: root,
  });
  console.log("Pi integrations: strict typecheck passed.");
} finally {
  await rm(temporary, { recursive: true, force: true });
}
