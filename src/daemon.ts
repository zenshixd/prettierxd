import net from "node:net";
import { createRequire } from "node:module";
import type Prettier from "prettier";
import { delayShutdown } from "./shutdown.js";
import {
  saveDaemonPid,
  killOtherDaemons,
  SOCKET_FILENAME,
} from "./singleton.js";
import { log, resetTime } from "./log.js";

export async function startDaemon() {
  await killOtherDaemons();
  const server = net.createServer().listen(SOCKET_FILENAME, async () => {
    await saveDaemonPid();
    return log(`Listening at ${SOCKET_FILENAME}`);
  });

  server.on("connection", handler);

  return () => {
    server.close();
  };
}

enum Parsing {
  Filepath,
  Range,
  Input,
}

interface State {
  parsing: Parsing;
  filepath: string;
  range: string;
  input: string;
}

const END_MARKER = "\0";
function handler(socket: net.Socket) {
  resetTime();
  delayShutdown();
  log("handler: new");
  let state: State = {
    parsing: Parsing.Filepath,
    filepath: "",
    range: "",
    input: "",
  };

  const parseFilepath = (data: string): boolean => {
    const endMarkerIndex = data.indexOf(END_MARKER);
    if (endMarkerIndex == -1) {
      state.filepath += data;
      return false;
    }

    state.filepath += data.slice(0, endMarkerIndex);
    state.parsing = Parsing.Range;

    return parseRange(data.slice(endMarkerIndex + END_MARKER.length));
  };

  const parseRange = (data: string): boolean => {
    const endMarkerIndex = data.indexOf(END_MARKER);
    if (endMarkerIndex == -1) {
      state.range += data;
      return false;
    }

    state.range += data.slice(0, endMarkerIndex);
    state.parsing = Parsing.Input;

    return parseInput(data.slice(endMarkerIndex + END_MARKER.length));
  };

  const parseInput = (data: string): boolean => {
    const endMarkerIndex = data.indexOf(END_MARKER);
    if (endMarkerIndex == -1) {
      state.input += data;
      return false;
    }

    state.input += data.slice(0, endMarkerIndex);
    return true;
  };

  socket.on("data", async (data) => {
    log("handler: data", data.toString().length);

    let doneParsing = false;
    switch (state.parsing) {
      case Parsing.Filepath:
        doneParsing = parseFilepath(data.toString());
        break;
      case Parsing.Range:
        doneParsing = parseRange(data.toString());
        break;
      case Parsing.Input:
        doneParsing = parseInput(data.toString());
        break;
    }

    if (doneParsing) {
      const prettier = resolvePrettier(state.filepath);
      const fileInfo = await prettier.getFileInfo(state.filepath, {
        ignorePath: ".prettierignore",
        resolveConfig: false,
      });
      if (fileInfo.ignored) {
        log("handler: ignored");
        socket.write(state.input + END_MARKER);
        socket.end();
        return;
      }

      const config = await resolveConfig(prettier, state.filepath);

      config.filepath = state.filepath;
      const [rangeStart, rangeEnd] = state.range
        .split(",")
        .map((x) => parseInt(x));
      if (rangeStart >= 0 && rangeEnd >= 0) {
        config.rangeStart = rangeStart;
        config.rangeEnd = rangeEnd;
      }

      log("handler: formatting", state.filepath);
      const output = await prettier.format(
        state.input.slice(0, -END_MARKER.length),
        config,
      );

      log("handler: formatted");
      socket.write(output + END_MARKER);
      socket.end();

      state = {
        parsing: Parsing.Filepath,
        filepath: "",
        range: "",
        input: "",
      };
    }
  });
}

const moduleCache = new Map<string, typeof Prettier>();
const require = createRequire(import.meta.url);

function resolvePrettier(filePath: string): typeof Prettier {
  if (moduleCache.has(filePath)) {
    log("resolvePrettier: cache hit");
    return moduleCache.get(filePath)!;
  }

  log("resolvePrettier: cache miss");
  const prettierPath = require.resolve("prettier", { paths: [filePath] });
  const prettierModule = require(prettierPath);
  moduleCache.set(filePath, prettierModule);
  log("resolvePrettier: resolved");
  return prettierModule;
}

const configFileCache = new Map<string, string | null>();
const configCache = new Map<string, Record<string, any>>();

async function resolveConfig(prettier: typeof Prettier, filePath: string) {
  log("resolveConfig");
  let configFile;
  if (configFileCache.has(filePath)) {
    log("resolveConfig: config file cache hit");
    configFile = configFileCache.get(filePath);
  } else {
    log("resolveConfig: config file cache miss");
    configFile = await prettier.resolveConfigFile(filePath);
    configFileCache.set(filePath, configFile);
  }

  log("resolveConfig: file", configFile);
  if (configFile == null) {
    return {};
  }

  if (configCache.has(configFile)) {
    log("resolveConfig: config cache hit");
    return configCache.get(configFile)!;
  }

  log("resolveConfig: config cache miss");
  let config = await prettier.resolveConfig(filePath, {
    config: configFile,
    useCache: false,
    editorconfig: true,
  });

  if (config == null) {
    config = {};
  }

  log("resolveConfig: config", config);
  configCache.set(configFile, config);
  return config;
}
