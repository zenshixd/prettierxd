const TIMEOUT = 30 * 60 * 1000;

let timer = setTimeout(() => {
  process.exit(0);
}, TIMEOUT);

export const delayShutdown = () => {
  clearTimeout(timer);
  timer = setTimeout(() => {
    process.exit(0);
  }, TIMEOUT);
};
