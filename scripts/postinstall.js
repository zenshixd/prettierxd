import { spawn } from "node:child_process";
import assert from "node:assert";
import { pipeline } from "node:stream/promises";
import path from "node:path";
import fs from "node:fs/promises";
import os from "node:os";
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
  spawn(
    `${tmpdir}/${getZigArchiveName()}/${ZIG_EXECUTABLE_NAME}`,
    ["build", "run", "-Doptimize=ReleaseFast", "--summary", "all"],
    {
      stdio: "inherit",
    },
  );
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
