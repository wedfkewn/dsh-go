// Verifies the bundled pnpm through the plugin manager's real install path.
// Unlike pnpm-smoke.mjs, this exercises compatibility preflight, run records,
// captured service output and manifest re-reading around an actual registry
// package. It needs network access:
//   node runtime/native-node/plugin-manager-smoke.mjs
import assert from 'node:assert/strict';
import {mkdir, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {installPnpmInProcess} from './pnpm-ios.mjs';

const PACKAGE = 'dsh-context';
const VERSION = '0.78.2';
const engine = resolve(process.argv[2] ?? 'app/ios/NativeNodeArtifacts/engine');
const operations = join(engine, 'node_modules/@deepseek-ai/dsh-plugin-manager/lib/types/operations.js');
const {runProfilePnpm} = await import(pathToFileURL(operations).href);
const command = installPnpmInProcess({
  distPath: join(engine, 'vendor/pnpm/dist/pnpm.mjs'),
  workerPath: new URL('./pnpm-worker.mjs', import.meta.url),
});

const root = await mkdtemp(join(tmpdir(), 'dsh-plugin-manager-smoke-'));
const profile = join(root, 'profile');
await mkdir(profile);
await writeFile(join(profile, 'package.json'), JSON.stringify({
  name: 'plugin-manager-smoke',
  private: true,
}));

let output = '';
try {
  const result = await runProfilePnpm(
    {dir: profile, profile: 'default', home: root, cwd: profile, installAnchor: join(engine, 'package.json')},
    ['add', `${PACKAGE}@${VERSION}`, '--save-exact', '--registry=https://registry.npmjs.org/'],
    {
      execution: 'service',
      command,
      args: [],
      env: {},
      outputBytes: 64 * 1024,
      lookupTimeoutMs: 120_000,
      idleTimeoutMs: 120_000,
      onOutput: chunk => { output += chunk; },
    },
  );
  assert.equal(result.exitCode, 0, output + '\n' + await readFile(result.logPath, 'utf8'));

  const manifest = JSON.parse(await readFile(join(profile, 'package.json'), 'utf8'));
  assert.equal(manifest.dependencies[PACKAGE], VERSION);
  const installed = JSON.parse(await readFile(join(profile, 'node_modules', PACKAGE, 'package.json'), 'utf8'));
  assert.equal(installed.version, VERSION);
  assert.match(output, new RegExp(PACKAGE));

  console.log(`plugin manager smoke: PASS (${PACKAGE}@${VERSION})`);
} finally {
  await rm(root, {recursive: true, force: true});
}
