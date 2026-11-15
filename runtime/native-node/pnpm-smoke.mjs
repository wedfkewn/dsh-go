// Verifies that the bundled pnpm runs through the spawn hook exactly as the
// plugin manager drives it: execa, captured stdio, a profile cwd and a
// sandbox-safe environment. Run on the host before an Xcode build:
//   node runtime/native-node/pnpm-smoke.mjs [ENGINE_DIR]
import assert from 'node:assert/strict';
import {mkdir, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {installPnpmInProcess} from './pnpm-ios.mjs';

const engine = resolve(process.argv[2] ?? 'app/ios/NativeNodeArtifacts/engine');
const {execa} = await import(pathToFileURL(join(engine, 'node_modules/execa/index.js')).href);
const command = installPnpmInProcess({
  distPath: join(engine, 'vendor/pnpm/dist/pnpm.mjs'),
  workerPath: new URL('./pnpm-worker.mjs', import.meta.url),
});

const root = await mkdtemp(join(tmpdir(), 'dsh-pnpm-smoke-'));
const profile = join(root, 'profile');
const dependency = join(root, 'dependency');
const secondDependency = join(root, 'second-dependency');
await mkdir(profile);
await mkdir(dependency);
await mkdir(secondDependency);
await writeFile(join(profile, 'package.json'), JSON.stringify({name: 'smoke', version: '1.0.0'}));
await writeFile(join(dependency, 'package.json'), JSON.stringify({name: 'smoke-dependency', version: '1.2.3'}));
await writeFile(join(dependency, 'index.js'), 'module.exports = 1;\n');
await writeFile(join(secondDependency, 'package.json'), JSON.stringify({name: 'smoke-second-dependency', version: '2.3.4'}));
await writeFile(join(secondDependency, 'index.js'), 'module.exports = 2;\n');

/** Run one pnpm command the way the plugin manager does: a captured service run. */
async function run(args, {withStoreDir = true} = {}) {
  const fullArgs = withStoreDir ? [...args, `--store-dir=${join(root, 'store')}`] : args;
  const child = execa(command, fullArgs, {
    cwd: profile, env: process.env, extendEnv: false, reject: false,
    stdout: 'pipe', stderr: 'pipe', killDescendants: true, buffer: false,
    stdin: 'ignore', cancelSignal: new AbortController().signal,
  });
  let stdout = '';
  let stderr = '';
  for await (const chunk of child.stdout) stdout += chunk;
  for await (const chunk of child.stderr) stderr += chunk;
  const result = await child;
  return {exitCode: result.exitCode, stdout, stderr};
}

try {
  const registry = await run(['config', 'get', 'registry'], {withStoreDir: false});
  assert.equal(registry.exitCode, 0, registry.stdout + registry.stderr);
  assert.match(registry.stdout, /^https:\/\/registry\.npmjs\.org\/?$/m);

  const added = await run(['add', `file:${dependency}`, '--save-exact']);
  assert.equal(added.exitCode, 0, added.stdout + added.stderr);
  const manifest = JSON.parse(await readFile(join(profile, 'package.json'), 'utf8'));
  assert.equal(manifest.dependencies['smoke-dependency'], `file:${dependency}`);
  assert.equal(JSON.parse(await readFile(join(profile, 'node_modules/smoke-dependency/package.json'), 'utf8')).version, '1.2.3');

  const modulesPath = join(profile, 'node_modules/.modules.yaml');
  const modules = await readFile(modulesPath, 'utf8');
  await writeFile(modulesPath, modules.replace(/^storeDir: .*$/m, `storeDir: ${join(root, 'missing-store')}`));
  const relocated = await run(['add', `file:${secondDependency}`, '--save-exact']);
  assert.equal(relocated.exitCode, 0, relocated.stdout + relocated.stderr);
  assert.doesNotMatch(relocated.stdout + relocated.stderr, /ERR_PNPM_UNEXPECTED_STORE/);
  const recoveredManifest = JSON.parse(await readFile(join(profile, 'package.json'), 'utf8'));
  assert.equal(recoveredManifest.dependencies['smoke-dependency'], `file:${dependency}`);
  assert.equal(recoveredManifest.dependencies['smoke-second-dependency'], `file:${secondDependency}`);
  assert.match(await readFile(join(profile, 'pnpm-lock.yaml'), 'utf8'), /smoke-second-dependency/);
  assert.equal(JSON.parse(await readFile(join(profile, 'node_modules/smoke-dependency/package.json'), 'utf8')).version, '1.2.3');
  assert.equal(JSON.parse(await readFile(join(profile, 'node_modules/smoke-second-dependency/package.json'), 'utf8')).version, '2.3.4');

  const missing = await run(['add', `file:${join(root, 'missing')}`, '--save-exact']);
  assert.equal(missing.exitCode, 1);
  assert.match(missing.stdout, /ERR_PNPM_LINKED_PKG_DIR_NOT_FOUND/);

  const removed = await run(['remove', 'smoke-dependency', 'smoke-second-dependency']);
  assert.equal(removed.exitCode, 0, removed.stdout + removed.stderr);
  assert.equal(JSON.parse(await readFile(join(profile, 'package.json'), 'utf8')).dependencies, undefined);

  console.log('pnpm smoke: PASS');
} finally {
  await rm(root, {recursive: true, force: true});
}
