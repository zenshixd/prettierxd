import { removePidFile } from "./singleton.js";

const TIMEOUT = 30 * 60 * 1000;

const exit = async () => {
  await removePidFile();
  process.exit(0);
};
let timer = setTimeout(exit, TIMEOUT);

export const delayShutdown = () => {
  clearTimeout(timer);
  timer = setTimeout(exit, TIMEOUT);
};
