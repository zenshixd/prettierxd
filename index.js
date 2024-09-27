import * as path from "node:path";
import * as net from "node:net";
import * as prettier from "prettier";

const TMP_DIR =
  process.platform === "win32"
    ? "C:\\Windows\\Temp"
    : process.platform === "darwin"
      ? "/private/tmp"
      : "/tmp";

const SOCKET_FILENAME = `${TMP_DIR}/prettierxd.sock`;
const END_MARKER = "\0";

main();

async function main() {
  const server = net
    .createServer()
    .listen(SOCKET_FILENAME, () => console.log("listening"));

  server.on("connection", (socket) => {
    let filepath = undefined;
    let input = "";
    socket.on("data", async (data) => {
      console.log("data", data.length);
      if (filepath == null) {
        const data_input = data.toString();
        const filename_split_index = data_input.indexOf(END_MARKER);

        filepath = data_input.slice(0, filename_split_index);
        input = data_input.slice(filename_split_index + 1);
      } else {
        input += data.toString();
      }

      console.log("checking delimiter: ", input.slice(-END_MARKER.length));
      if (input.endsWith(END_MARKER)) {
        console.log("formatting ", filepath);
        const config = (await prettier.resolveConfig(filepath)) ?? {};
        config.filepath = filepath;

        const output = await prettier.format(
          input.slice(0, -END_MARKER.length),
          config,
        );

        socket.write(output);
        socket.end();
        filepath = undefined;
        input = "";
      }
    });
  });
}
