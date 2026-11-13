import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, readFile, rename, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {setTimeout as sleep} from 'node:timers/promises';

const engine = resolve(process.argv[2] ?? 'app/ios/NativeNodeArtifacts/engine');
const root = await mkdtemp(join(tmpdir(), 'dsh-native-node-test-'));
await Promise.all(['home', 'tmp'].map(dir => mkdir(join(root, dir))));
const host = spawn(process.execPath, ['--expose-internals', join(engine, 'supervisor.mjs'), root], {
  stdio: 'ignore',
});
const closed = new Promise(done => host.once('close', done));

async function transition(action, generation, phase) {
  const pending = join(root, 'command.tmp');
  await writeFile(pending, JSON.stringify({action, generation}));
  await rename(pending, join(root, 'command.json'));
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    let state;
    try {
      state = JSON.parse(await readFile(join(root, 'status.json'), 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (state?.generation === generation) {
      if (state.phase === 'error') throw new Error(state.error.code);
      if (state.phase === phase) return state;
    }
    await sleep(150);
  }
  throw new Error('Timed out waiting for ' + phase);
}

async function verify(state) {
  const signal = AbortSignal.timeout(5000);
  const anonymous = await fetch(state.baseUrl, {redirect: 'manual', signal});
  await anonymous.body?.cancel();
  assert.ok([401, 403].includes(anonymous.status));
  const url = new URL(state.baseUrl);
  url.searchParams.set('token', state.token);
  const exchange = await fetch(url, {redirect: 'manual', signal});
  await exchange.body?.cancel();
  const cookie = exchange.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
  assert.ok(cookie);
  const signedIn = await fetch(state.baseUrl, {headers: {cookie}, redirect: 'manual', signal});
  await signedIn.body?.cancel();
  assert.equal(signedIn.status, 200);
}

try {
  const first = await transition('start', 'first', 'candidate');
  await verify(first);
  const second = await transition('start', 'second', 'candidate');
  await verify(second);
  assert.notEqual(second.token, first.token);
  await transition('stop', 'stop', 'stopped');
  await assert.rejects(fetch(second.baseUrl, {signal: AbortSignal.timeout(3000)}));
  console.log('PASS DSH ESM Worker start, localhost auth, restart with fresh token, and stop');
} finally {
  host.kill();
  await closed;
  await rm(root, {recursive: true, force: true});
}
