import { execFileSync, spawn } from "node:child_process";
import assert from "node:assert";
import { pipeline } from "node:stream/promises";
import path from "node:path";
import fs from "node:fs/promises";
import os from "node:os";
import { fileURLToPath } from "node:url";
import * as tar from "tar-stream";
import unzipper from "unzipper";
import xz from "xz-decompress";

const tmpdir = os.tmpdir();
const ZIG_VERSION = "0.13.0";
const ZIG_EXECUTABLE_NAME = process.platform === "win32" ? "zig.exe" : "zig";
build();

async function build() {
  await downloadZig();
  console.log("Compiling prettierxd...");
  const cwd = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
  execFileSync(
    `${tmpdir}/${getZigArchiveName()}/${ZIG_EXECUTABLE_NAME}`,
    ["build", "run", "-Doptimize=ReleaseFast", "--summary", "all"],
    {
      cwd,
      stdio: "inherit",
    },
  );

  if (process.platform === "win32") {
    console.log("We are on windows, we need to fix links ...");
    await fixWindowsLinks(cwd);
  }
}

function getZigArchiveName() {
  const { arch, platform } = process;

  let zigPlatformVariant;
  let zigArchVariant;

  switch (platform) {
    case "darwin":
      zigPlatformVariant = "macos";
      break;
    case "win32":
      zigPlatformVariant = "windows";
      break;
    case "linux":
    case "freebsd":
    case "openbsd":
      zigPlatformVariant = "linux";
      break;
    default:
      throw new Error(`Unsupported platform: ${platform}`);
  }

  switch (arch) {
    case "x64":
      zigArchVariant = "x86_64";
      break;
    case "arm64":
      zigArchVariant = "aarch64";
      break;
    case "ia32":
      zigArchVariant = "x86";
      break;
    default:
      throw new Error(`Unsupported architecture: ${arch}`);
  }

  return `zig-${zigPlatformVariant}-${zigArchVariant}-${ZIG_VERSION}`;
}

function getZigDownloadUrl() {
  const extension = process.platform === "win32" ? "zip" : "tar.xz";
  return `https://ziglang.org/download/${ZIG_VERSION}/${getZigArchiveName()}.${extension}`;
}

async function downloadZig() {
  const downloadUrl = getZigDownloadUrl();
  console.log(`Downloading Zig from ${downloadUrl}`);
  const response = await fetch(downloadUrl);
  assert.ok(response.ok, response.statusText);

  if (process.platform === "win32") {
    await unpackZip(response);
  } else {
    await unpackTarXz(response);
  }
}

async function unpackZip(response) {
  const size = parseInt(response.headers.get("content-length"));
  assert.ok(size > 0, "Invalid zip file");

  const source = await unzipper.Open.buffer(
    Buffer.from(await response.arrayBuffer()),
  );

  for (const file of source.files) {
    const fullPath = path.join(tmpdir, file.path);
    if (file.type === "Directory") {
      await fs.mkdir(fullPath, { recursive: true });
    } else {
      const dest = await fs.open(fullPath, "w+", 0o755);
      await pipeline(file.stream(), dest.createWriteStream());
      await dest.close();
    }
  }
}

async function unpackTarXz(response) {
  console.log(`Extracting zig compiler to ${tmpdir}...`);
  const extract = tar.extract();

  extract.on("entry", async (header, stream, next) => {
    const fullPath = path.join(tmpdir, header.name);
    if (header.type === "directory") {
      await fs.mkdir(fullPath, { recursive: true });
      next();
    } else {
      const dest = await fs.open(fullPath, "w+", 0o755);
      stream.pipe(dest.createWriteStream());
      stream.on("end", async () => {
        await dest.close();
        next();
      });
    }
  });

  await pipeline(new xz.XzReadableStream(response.body), extract);
}

const DEFAULT_LINKS = [
  "prettierxd",
  "prettierxd.cmd",
  "prettierxd.ps1",
  "prettierxd.exe",
  "prettierxd.exe.cmd",
  "prettierxd.exe.ps1",
];
async function fixWindowsLinks(cwd) {
  const nodeDir =
    process.env.npm_config_prefix ?? path.dirname(process.argv[0]);

  // Remove existing links cause they suck
  const files = await fs.readdir(nodeDir);
  for (const file of files) {
    if (DEFAULT_LINKS.includes(file)) {
      await fs.unlink(path.join(nodeDir, file));
    }
  }

  await fs.copyFile(
    path.join(cwd, "zig-out", "bin", "prettierxd.exe"),
    path.join(nodeDir, "prettierxd.exe"),
  );
  console.log("Copied binary to PATH");
}
