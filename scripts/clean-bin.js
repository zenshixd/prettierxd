import fs from "node:fs/promises";
import path from "node:path";
import url from "node:url";

async function clean() {
  const binPath = path.join(
    path.dirname(url.fileURLToPath(import.meta.url)),
    "..",
    "zig-out",
    "bin",
  );
  const files = await fs.readdir(binPath);
  for (const file of files) {
    await fs.unlink(path.join(binPath, file));
  }
  await fs.writeFile(path.join(binPath, "prettierxd"), "", {
    flag: "w+",
  });
  await fs.writeFile(path.join(binPath, "prettierxd.exe"), "", {
    flag: "w+",
  });
  console.log("Cleaning ./zig-out/bin directory done.");
}

clean();
