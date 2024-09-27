import * as net from "node:net";
import * as fs from "node:fs/promises";
import * as prettier from "prettier";
// dupa udpasdadsalkdjsaldksajdslkadjsakldjsaldkd
//
async function main() {
  await fs.rm("/tmp/prettierd.sock");
  const server = net
    .createServer()
    .listen("/tmp/prettierd.sock", 1, () => console.log("listening"));

  server.on("connection", (socket) => {
    let filepath = undefined;
    let input = "";
    socket.on("data", async (data) => {
      console.log("data", data.length);
      if (filepath == null) {
        const data_input = data.toString();
        const filename_split_index = data_input.indexOf("$");

        filepath = data_input.slice(0, filename_split_index);
        input = data_input.slice(filename_split_index + 1);
      } else {
        input += data.toString();
      }

      console.log("checking delimiter: ", input.slice(-3));
      if (input.endsWith("$$$")) {
        console.log("formatting ", filepath);
        const output = await prettier.format(input.slice(0, -3), { filepath });
        socket.write(output);
        socket.end();
        filepath = undefined;
        input = "";
      }
    });
  });
}

main();
