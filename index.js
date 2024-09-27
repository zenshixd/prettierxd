import * as net from "node:net";
import * as fs from "node:fs/promises";
import * as prettier from "prettier";

async function main() {
  try {
    await fs.access("/tmp/prettierd.sock");
    await fs.rm("/tmp/prettierd.sock");
  } catch (e) {
    // ignore
  }
  const server = net
    .createServer()
    .listen("/tmp/prettierd.sock", 1, () => console.log("listening"));

  server.on("connection", (socket) => {
    socket.on("data", (data) => {
      console.log("data", data.toString());
      socket.write(data);
    });
  });
}

main();
