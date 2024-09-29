import net from "node:net";
import path from "node:path";
import { Console } from "node:console";
import fs from "node:fs";
import * as prettier from "prettier";

const TMP_DIR =
  process.platform === "win32"
    ? "C:\\Windows\\Temp"
    : process.platform === "darwin"
      ? "/private/tmp"
      : "/tmp";

export const SOCKET_FILENAME = `${TMP_DIR}/prettierxd.sock`;
const END_MARKER = "\0";

export function startDaemon() {
  const stdout = fs.createWriteStream(path.join(TMP_DIR, "prietterxd.log"));
  const stderr = fs.createWriteStream(path.join(TMP_DIR, "prietterxd.err.log"));
  const console = new Console({ stdout, stderr });

  const server = net
    .createServer()
    .listen(SOCKET_FILENAME, () =>
      console.log(`Listening at ${SOCKET_FILENAME}`),
    );

  server.on("connection", (socket) => {
    console.log("New connection!");
    let filepath = undefined;
    let rangeStart = undefined;
    let rangeEnd = undefined;
    let input = "";

    socket.on("data", async (data) => {
      console.log("input data", data.toString().length);
      if (filepath == null) {
        const chunk = parseFirstChunk(data.toString());
        filepath = chunk.path;
        rangeStart = chunk.rangeStart;
        rangeEnd = chunk.rangeEnd;
        input = chunk.input;
        console.log("parsed chunk", chunk);
      } else {
        input += data.toString();
      }

      console.log(
        "Checking delimiter: ",
        encodeURIComponent(input.slice(-END_MARKER.length)),
      );
      if (input.endsWith(END_MARKER)) {
        console.log("Formatting ", filepath);
        const config = (await prettier.resolveConfig(filepath)) ?? {};

        config.filepath = filepath;
        if (rangeStart >= 0 && rangeEnd >= 0) {
          config.rangeStart = rangeStart;
          config.rangeEnd = rangeEnd;
        }

        console.log("config", config);
        const output = await prettier.format(
          input.slice(0, -END_MARKER.length),
          config,
        );

        socket.write(output);
        socket.end();
        filepath = undefined;
        rangeStart = undefined;
        rangeEnd = undefined;
        input = "";
      }
    });
  });

  return () => {
    server.close();
    try {
      fs.unlinkSync(SOCKET_FILENAME);
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
  };
}

export function parseFirstChunk(data) {
  const pathEndIndex = data.indexOf(END_MARKER);
  const path = data.slice(0, pathEndIndex);
  const rangeEndIndex = data.indexOf(END_MARKER, pathEndIndex + 1);
  const range = data.slice(pathEndIndex + END_MARKER.length, rangeEndIndex);
  const input = data.slice(rangeEndIndex + END_MARKER.length);

  const [rangeStart, rangeEnd] = range.split(",").map((x) => parseInt(x));
  return { path, rangeStart, rangeEnd, input };
}