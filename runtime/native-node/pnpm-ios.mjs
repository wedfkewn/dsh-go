/**
 * Runs the bundled pnpm inside the app's own process tree.
 *
 * iOS forbids fork()/exec(), so child_process.spawn() can never start pnpm
 * from the sandbox. Every pnpm invocation made through `spawn` is redirected
 * to a worker thread that loads the bundled pnpm distribution and reports
 * back as if it were a child process: same argv, cwd, environment and
 * stdout/stderr pipes, so the caller (execa, and through it the plugin
 * manager) observes an ordinary ChildProcess.
 */
import childProcess from 'node:child_process';
import {EventEmitter} from 'node:events';
import {syncBuiltinESMExports} from 'node:module';
import {basename} from 'node:path';
import {PassThrough, Writable} from 'node:stream';
import {Worker} from 'node:worker_threads';

/** Executable name the profile context hands to pnpm call sites. It never exists on disk. */
export const PNPM_IN_PROCESS_COMMAND = '/pnpm-in-process';

const PNPM_EXECUTABLES = new Set(['pnpm', 'pnpm.cmd', 'pnpm.exe']);
/** A pid no run in the app owns: a stale operation's liveness probe must not find a live group. */
const SYNTHETIC_PID = 2_147_483_000;

/**
 * Route every pnpm executable to the bundled copy.
 * @param options Bundled pnpm entry point and the worker that runs it.
 * @returns The command a profile context should hand to pnpm call sites.
 */
export function installPnpmInProcess({distPath, workerPath, command = PNPM_IN_PROCESS_COMMAND}) {
  const realSpawn = childProcess.spawn;
  childProcess.spawn = function spawn(file, args, options) {
    if (isPnpmExecutable(file, command)) {
      return spawnPnpmInProcess(args ?? [], options ?? {}, {distPath, workerPath, command});
    }
    return realSpawn.apply(this, arguments);
  };
  // execa imported `spawn` before this hook ran, so its ESM binding must be refreshed.
  syncBuiltinESMExports();
  return command;
}

function isPnpmExecutable(file, command) {
  if (typeof file !== 'string') return false;
  return file === command || PNPM_EXECUTABLES.has(basename(file).toLowerCase());
}

/**
 * A ChildProcess-shaped handle backed by a worker thread.
 * @param args pnpm command line, without the executable.
 * @param options spawn options: cwd, env, stdio.
 * @param paths Bundled pnpm entry point, worker entry and the hooked command.
 * @returns The fake child process.
 */
function spawnPnpmInProcess(args, options, {distPath, workerPath, command}) {
  const child = new EventEmitter();
  const stdio = Array.isArray(options.stdio) ? options.stdio : ['pipe', 'pipe', 'pipe'];
  const out = createSink(stdio[1], process.stdout);
  const err = createSink(stdio[2], process.stderr);
  // pnpm never prompts here: the plugin manager passes --no-frozen-lockfile style
  // flags and no interactive commands. An input pipe is drained and discarded.
  const input = stdio[0] === 'pipe' ? new Writable({write(_chunk, _encoding, done) { done(); }}) : null;

  child.pid = SYNTHETIC_PID;
  child.stdin = input;
  child.stdout = out.stream;
  child.stderr = err.stream;
  child.stdio = [input, out.stream, err.stream];
  child.exitCode = null;
  child.signalCode = null;
  child.killed = false;
  child.spawnfile = command;
  child.spawnargs = [command, ...args];

  let settled = false;
  const finish = (code, signal) => {
    if (settled) return;
    settled = true;
    child.exitCode = code;
    child.signalCode = signal;
    child.emit('exit', code, signal);
    const streams = [out.stream, err.stream].filter(stream => stream !== null);
    for (const stream of streams) stream.end();
    Promise.all(streams.map(stream => new Promise(done => stream.once('close', done))))
      .then(() => child.emit('close', code, signal));
  };

  const token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  const worker = new Worker(workerPath, {
    workerData: {token, cwd: options.cwd ?? process.cwd(), distPath, argv: args,
      env: options.env ?? process.env},
  });

  child.kill = signal => {
    if (settled) return false;
    child.killed = true;
    void worker.terminate();
    finish(null, typeof signal === 'string' ? signal : 'SIGTERM');
    return true;
  };

  worker.on('message', message => {
    if (message?.token !== token) return;
    if (message.type === 'data') {
      (message.stream === 'stderr' ? err : out).write(String(message.text ?? ''));
    } else if (message.type === 'exit') {
      if (typeof message.error === 'string') err.write(message.error.endsWith('\n') ? message.error : `${message.error}\n`);
      worker.postMessage({type: 'ack'});
    }
  });
  worker.on('error', error => {
    err.write(`${error?.stack ?? error}\n`);
    finish(1, null);
  });
  worker.on('exit', code => finish(code ?? 1, null));
  process.nextTick(() => child.emit('spawn'));
  return child;
}

function createSink(mode, inherited) {
  if (mode === 'pipe' || mode === undefined) {
    const stream = new PassThrough();
    return {stream, write: text => { stream.write(text); }};
  }
  if (mode === 'ignore' || mode === null) return {stream: null, write: () => {}};
  return {stream: null, write: text => { inherited.write(text); }};
}
