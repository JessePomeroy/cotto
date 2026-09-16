import { acquireDataDirectoryLock } from "../../src/data-lock";

try {
  const directory = process.argv[2];
  if (!directory) throw new Error("Missing test directory.");
  const lock = acquireDataDirectoryLock(directory);
  console.log("acquired");
  if (process.argv[3] === "--hold") setInterval(() => {}, 1_000);
  else lock.release();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
