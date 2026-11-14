import {readFile, rename, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {Worker} from 'node:worker_threads';

const root = process.argv[2];
let generation;
let worker;
let changing = false;
const status = join(root, 'status.json');

let writes = Promise.resolve();

function report(value) {
  const next = writes.then(async () => {
    if (value.generation !== generation) return;
    const file = status + '.tmp';
    await writeFile(file, JSON.stringify(value), {mode: 0o600});
    if (value.generation === generation) await rename(file, status);
  });
  writes = next.catch(() => {});
  return next;
}

async function poll() {
  if (changing) return;
  changing = true;
  try {
    const next = JSON.parse(await readFile(join(root, 'command.json'), 'utf8'));
    if (next.generation === generation) return;
    generation = next.generation;
    if (worker) await worker.terminate();
    worker = undefined;
    const identity = generation;
    if (next.action === 'stop') {
      await report({generation, phase: 'stopped'});
      return;
    }
    await report({generation, phase: 'starting'});
    const engine = new Worker(new URL('./engine-worker.mjs', import.meta.url), {
      workerData: {root},
      env: {...process.env, HOME: join(root, 'home'), DSH_HOME: join(root, 'home', '.dsh'),
        TMPDIR: join(root, 'tmp')},
    });
    worker = engine;
    const publish = value => {
      if (generation === identity) void report({generation: identity, ...value}).catch(() => {});
    };
    engine.on('message', publish);
    let failed = false;
    engine.once('error', error => {
      failed = true;
      publish({phase: 'error', error: {code: error.code || error.name, message: 'DSH Worker startup failed.'}});
    });
    engine.once('exit', code => {
      if (!failed) publish({phase: 'error', error: {code: 'native_node_worker_exit', message: 'DSH Worker exited (' + code + ').'}});
    });
  } catch (error) {
    if (error.code !== 'ENOENT' && generation !== undefined) {
      await report({generation, phase: 'error', error: {code: error.code || 'native_node_supervisor_error', message: 'Native Node supervisor failed.'}});
    }
  } finally {
    changing = false;
  }
}

setInterval(poll, 150);
