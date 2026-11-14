import {existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {parentPort} from 'node:worker_threads';

if (!['24.20.0', '24.22.3'].includes(process.versions.node)) throw new Error('Unsupported Node version');

const output = process.stdout.write.bind(process.stdout);
process.stdout.write = (chunk, ...args) => {
  const text = String(chunk);
  for (const match of text.matchAll(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9._~%+-]+)/g)) {
    parentPort.postMessage({phase: 'candidate', baseUrl: 'http://127.0.0.1:' + match[1],
      token: decodeURIComponent(match[2]), nodeVersion: process.versions.node});
  }
  if (/127\.0\.0\.1.*token=/.test(text)) return true;
  return output(chunk, ...args);
};
const entry = new URL('./node_modules/@deepseek-ai/dsh/lib/bin.js', import.meta.url);
process.argv = [process.execPath, fileURLToPath(entry), 'web', '--no-open', '--host', '127.0.0.1', '--port', '0'];

// iOS has no fork()/exec(), so the app ships pnpm and runs it in-process. The
// profile context then hands every plugin operation this command instead of
// resolving `pnpm` from PATH, where a sandboxed app has none.
const pnpmDist = fileURLToPath(new URL('./vendor/pnpm/dist/pnpm.mjs', import.meta.url));
let packageManager;
if (existsSync(pnpmDist)) {
  const {installPnpmInProcess} = await import(new URL('./pnpm-ios.mjs', import.meta.url));
  packageManager = {command: installPnpmInProcess({
    distPath: pnpmDist, workerPath: new URL('./pnpm-worker.mjs', import.meta.url),
  }), args: [], env: {}};
}
parentPort.postMessage({phase: 'starting', nodeVersion: process.versions.node});
const {runCli} = await import(entry);
await runCli(packageManager === undefined ? {} : {packageManager});
