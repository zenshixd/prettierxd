import { test, before, after } from "node:test";
import net from "node:net";
import assert from "node:assert";
import { startDaemon } from "./daemon.js";
import { SOCKET_FILENAME } from "./singleton.js";

let daemonStop: () => void;
before(async () => {
  daemonStop = await startDaemon();
});

after(() => {
  console.log("stopping daemon");
  daemonStop();
});

test("should reformat code", async () => {
  return new Promise<void>((resolve) => {
    const socket = net.createConnection(
      {
        path: SOCKET_FILENAME,
      },
      () => {
        console.log("connected");
      },
    );

    socket.on("data", (data) => {
      const result = data.toString();
      console.log("data", result);
      assert.equal(result, 'console.log("hello");\0');
      socket.end();
      resolve();
    });

    socket.write(
      "index.js\0" +
        "0,10\0" +
        ".prettierignore\0" +
        "console.log('hello');\n\0",
    );
  });
});
