import path from "node:path";
import { tmpdir } from "node:os";
import fs from "node:fs/promises";

let timeStart: bigint;

let logFile: fs.FileHandle;
let logPromise: Promise<void> = Promise.resolve();

export const log = (...args: any[]) => {
  if (process.argv.includes("--debug")) {
    return console.log(...args, `[${readTime() / 1000n}μs elapsed]`);
  }

  logPromise = logPromise.then(async () => {
    if (logFile == null) {
      logFile = await fs.open(path.join(tmpdir(), "prettierxd.log"), "w+");
    }
    return logFile.writeFile(
      args.join(" ") + `[${readTime() / 1000n}μs elapsed]` + "\n",
    );
  });
};

export const logError = (...args: any[]) => log("error:", ...args);
export function readTime() {
  if (timeStart == null) {
    timeStart = process.hrtime.bigint();
    return 0n;
  }
  return process.hrtime.bigint() - timeStart;
}
