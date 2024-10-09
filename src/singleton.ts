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
  const pid = await readPidFile();
  if (pid != null) {
    if (pid == process.pid) {
      log("killOtherDaemons: already running");
      return;
    }

    log("killOtherDaemons: killing", pid);
    const killResult = killProcess(pid);
    if (!killResult) {
      log("killOtherDaemons: process not found");
    }
  } else {
    log("killOtherDaemons: no pid file");
  }

  // on Linux/Mac also remove the unix socket file
  if (process.platform !== "win32") {
    log("killOtherDaemons: removing socket file");
    const removed = await unlinkFile(SOCKET_FILENAME);
    if (!removed) {
      log("killOtherDaemons: socket file not found");
    }
  }
}

async function readPidFile() {
  try {
    return parseInt(await readFile(PID_FILE, "utf-8"));
  } catch (e) {
    if ((e as any).code === "ENOENT") {
      return null;
    }

    throw e;
  }
}

function killProcess(pid: number) {
  try {
    process.kill(pid, "SIGTERM");
    return true;
  } catch (e) {
    if ((e as any).code === "ESRCH") {
      return false;
    }

    throw e;
  }
}

export async function unlinkFile(file: string) {
  try {
    await unlink(file);
    return true;
  } catch (e) {
    if ((e as any).code === "ENOENT") {
      return false;
    }

    throw e;
  }
}

export async function removePidFile() {
  log("removePidFile");
  await unlinkFile(PID_FILE);
}
