import { readFile, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { log } from "./log.js";

export const SOCKET_FILENAME = path.join(
  process.platform === "win32" ? "\\\\?\\pipe" : tmpdir(),
  "prettierxd.sock",
);
export const PID_FILE = path.join(tmpdir(), "prettierxd.pid");

export async function saveDaemonPid() {
  log("saveDaemonPid", process.pid);
  await writeFile(PID_FILE, process.pid.toString());
}

export async function killOtherDaemons() {
  log("killOtherDaemons");
  try {
    const pid = parseInt(await readFile(PID_FILE, "utf-8"));
    if (pid == process.pid) {
      log("killOtherDaemons: already running");
      return;
    }

    log("killOtherDaemons: killing", pid);
    process.kill(pid, "SIGTERM");
  } catch (e) {
    log("killOtherDaemons: error", e);
    if ((e as any).code !== "ENOENT" && (e as any).code !== "ESRCH") throw e;
  }

  // on Linux/Mac also remove the unix socket file
  if (process.platform !== "win32") {
    try {
      log("killOtherDaemons: removing socket file");
      await unlink(SOCKET_FILENAME);
    } catch (e) {
      log("killOtherDaemons: removing socket file error", e);
      if ((e as any).code !== "ENOENT") throw e;
    }
  }
}

export async function removePidFile() {
  log("removePidFile");
  await unlink(PID_FILE);
}
