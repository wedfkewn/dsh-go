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
parentPort.postMessage({phase: 'starting', nodeVersion: process.versions.node});
const {runCli} = await import(entry);
await runCli();
