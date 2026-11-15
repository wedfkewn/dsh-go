/**
 * Worker-thread entry that runs the bundled pnpm distribution.
 *
 * A worker owns its own argv and environment, so the DSH process that hosts
 * the web server is untouched: pnpm's process.exit() leaves only this thread,
 * and its global side effects (signal handlers, reporters, worker pool) stay
 * inside the run.
 */
import {parentPort, workerData} from 'node:worker_threads';
import Module, {createRequire, enableCompileCache} from 'node:module';
import {readFile, rm, stat} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

const {token, cwd, distPath, argv, env} = workerData;
const post = message => parentPort.postMessage({token, ...message});
const decode = (chunk, encoding) => typeof chunk === 'string'
  ? chunk
  : Buffer.from(chunk).toString(typeof encoding === 'string' ? encoding : 'utf8');

for (const name of Object.keys(process.env)) delete process.env[name];
Object.assign(process.env, env);

process.stdout.write = (chunk, ...rest) => {
  post({type: 'data', stream: 'stdout', text: decode(chunk, rest[0])});
  return true;
};
process.stderr.write = (chunk, ...rest) => {
  post({type: 'data', stream: 'stderr', text: decode(chunk, rest[0])});
  return true;
};

// pnpm reads its command line from process.argv and its working directory from
// process.cwd(). Workers cannot chdir, so the caller's cwd is passed as pnpm's
// own --dir option, which makes pnpm resolve the profile exactly as if it had
// been started there.
process.argv = [process.execPath, distPath, '--dir', cwd, ...argv];

const realExit = process.exit.bind(process);
let leaving = false;
/** Report the run's outcome, then leave once the host has received it. */
const leave = (code, error) => {
  if (leaving) return;
  leaving = true;
  const status = typeof code === 'number' ? code : Number(process.exitCode ?? 0);
  post({type: 'exit', code: status, ...(error === undefined ? {} : {error: String(error)})});
  parentPort.once('message', message => {
    if (message?.type === 'ack') realExit(status);
  });
};
// pnpm ends every command with exit(), which on iOS must not end the app.
process.exit = code => leave(code);

// pnpm's macOS store importer prefers a native reflink addon that cannot load
// in the app sandbox. Answer the module load with an addon that reports the
// capability as unavailable, so pnpm copies through the store as it does on
// platforms without reflink support.
const requireFromPnpm = createRequire(distPath);
try {
  requireFromPnpm('@reflink/reflink');
} catch {
  const load = Module._load;
  Module._load = function loadModule(request, parent, isMain) {
    if (request === '@reflink/reflink') {
      const unavailable = () => {
        const error = new Error('reflink is unavailable in this sandbox');
        error.code = 'ENOTSUP';
        throw error;
      };
      return {
        reflinkFileSync: unavailable,
        reflinkFile: async (...args) => unavailable(...args),
      };
    }
    return load.apply(this, arguments);
  };
}

const writeCommands = new Set([
  'add', 'install', 'i', 'remove', 'uninstall', 'rm', 'un', 'uni',
  'update', 'up', 'upgrade', 'dedupe', 'prune',
]);
const command = argv.find(arg => !arg.startsWith('-'));

// An iOS app update can move its data container while pnpm's derived
// node_modules tree still records the old store. Rebuild only that tree when
// the recorded store is gone; pnpm itself persists package.json and the lock.
if (writeCommands.has(command)) {
  const modulesDir = join(cwd, 'node_modules');
  try {
    const modules = requireFromPnpm('yaml').parse(
      await readFile(join(modulesDir, '.modules.yaml'), 'utf8'),
    );
    const storeDir = modules?.storeDir;
    if (typeof storeDir === 'string' && storeDir !== '') {
      try {
        await stat(storeDir);
      } catch (error) {
        if (error?.code === 'ENOENT') await rm(modulesDir, {recursive: true, force: true});
      }
    }
  } catch {
    // Missing or unreadable metadata is left for pnpm's normal diagnostics.
  }
}

try {
  enableCompileCache?.();
} catch {
  // The cache is an optimisation; pnpm runs without it.
}

try {
  await import(pathToFileURL(distPath).href);
} catch (error) {
  leave(1, error?.stack ?? error);
}
