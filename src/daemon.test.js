import { test, beforeEach, afterEach } from "node:test";
import net from "node:net";
import assert from "node:assert";
import { SOCKET_FILENAME, startDaemon, parseFirstChunk } from "./daemon.js";

let daemonStop;
beforeEach(() => {
  daemonStop = startDaemon();
});

afterEach(() => {
  daemonStop();
});

test("should reformat code", (t, done) => {
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
    assert.equal(result, 'console.log("hello");\n');
    socket.end();
    done();
  });

  socket.write("index.js" + "\0" + "0,10\0console.log('hello');\n\0");
});

test("should parse first chunk", () => {
  const result = parseFirstChunk(
    "index.js" + "\0" + "0,10\0console.log('hello');\n\0",
  );
  assert.equal(result.path, "index.js");
  assert.equal(result.rangeStart, 0);
  assert.equal(result.rangeEnd, 10);
  assert.equal(result.input, "console.log('hello');\n\0");
});
