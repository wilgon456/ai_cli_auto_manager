'use strict';
// lib/optimize.js with fake npm/uv/pnpm (tests/fixtures/optimize-fake.js) and fake process tables
// (AICM_PROCESS_LIST). Runs on macOS, Linux and Windows (there the fakes are .cmd shims, so the
// cmd.exe launch path is exercised for real). No real package manager or cache is ever reached.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(__dirname, '../..');
const js = path.join(root, 'lib/optimize.js');
const fake = path.join(root, 'tests/fixtures/optimize-fake.js');
const opt = require(js);
const WIN = process.platform === 'win32';

function setup(opts = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-opt-'));
  const home = path.join(dir, 'user');
  const aicm = path.join(home, '.ai-cli-auto-manager');
  const bin = path.join(dir, opts.binName || 'fake bin');
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(bin, { recursive: true });
  if (opts.claim !== false) {
    fs.mkdirSync(aicm, { recursive: true });
    fs.writeFileSync(path.join(aicm, '.aicm-home'), 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n');
  }
  for (const name of opts.tools || ['npm', 'uv', 'pnpm']) {
    if (WIN) fs.writeFileSync(path.join(bin, `${name}.cmd`), `@"${process.execPath}" "${fake}" ${name} %*\r\n`);
    else {
      const p = path.join(bin, name);
      fs.writeFileSync(p, `#!/bin/sh\nexec "${process.execPath}" "${fake}" ${name} "$@"\n`);
      fs.chmodSync(p, 0o755);
    }
  }
  const calls = path.join(dir, 'calls.jsonl');
  const procs = path.join(dir, 'procs.json');
  fs.writeFileSync(procs, JSON.stringify([{ pid: 1, ppid: 0, name: 'init', cmd: '/sbin/init' }]));
  const sys = WIN ? [path.join(process.env.SystemRoot || 'C:\\Windows', 'System32')] : ['/usr/bin', '/bin'];
  const base = { ...process.env };
  for (const k of Object.keys(base)) if (k.toUpperCase() === 'PATH') delete base[k];
  const env = {
    ...base, HOME: home, USERPROFILE: home, AICM_HOME: aicm, PATH: [bin, ...sys].join(path.delimiter),
    FAKE_OPTIMIZE_CALLS: calls, FAKE_OPTIMIZE_GRANDCHILD: path.join(dir, 'grandchild.pid'), AICM_PROCESS_LIST: procs,
  };
  for (const k of Object.keys(env)) if (k.startsWith('AICM_MAINTENANCE_') || k === 'AICM_OPTIMIZE_TIMEOUT') delete env[k];
  return { dir, home, aicm, bin, calls, procs, env };
}

function run(fx, args, extra = {}) {
  return spawnSync(process.execPath, [js, ...args], { env: { ...fx.env, ...extra }, encoding: 'utf8', timeout: 120000 });
}
function calls(fx) {
  if (!fs.existsSync(fx.calls)) return [];
  return fs.readFileSync(fx.calls, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
}
function one(stdout) {
  const text = stdout.trim();
  assert.equal(text.split('\n').length, 1, 'one JSON line');
  return JSON.parse(text);
}

test('preview (default and --dry-run) resolves tools only: nothing runs, nothing is written', () => {
  const fx = setup({ claim: false });
  for (const args of [['--json'], ['--dry-run', '--json'], ['--tasks', 'npm-verify,pnpm-prune', '--json']]) {
    const r = run(fx, args);
    assert.equal(r.status, 0, r.stderr);
    const d = one(r.stdout);
    assert.equal(d.mode, 'preview');
    assert.equal(d.dryRun, true);
    assert.ok(d.tasks.every((t) => t.status === 'would-run' && t.executable && t.executable.startsWith(fx.bin)), r.stdout);
  }
  assert.deepEqual(calls(fx), []);
  assert.equal(fs.existsSync(fx.aicm), false, 'a preview creates no AICM_HOME');
  const human = run(fx, []);
  assert.equal(human.status, 0);
  assert.match(human.stdout, /preview: nothing is run/);
  assert.deepEqual(calls(fx), []);
});

test('a missing tool is unavailable with a reason, never a success', () => {
  const fx = setup({ tools: ['npm'] });
  const p = one(run(fx, ['--json']).stdout);
  assert.deepEqual(p.tasks.map((t) => t.status), ['would-run', 'unavailable', 'unavailable']);
  assert.match(p.tasks[1].reason, /uv not found on PATH/);
  const r = run(fx, ['--apply', '--json']);
  assert.equal(r.status, 1, 'unavailable tasks are not success');
  const d = one(r.stdout);
  assert.equal(d.summary.succeeded, 1);
  assert.equal(d.summary.unavailable, 2);
  assert.equal(d.status, 'partial');
});

test('invalid options are refused before anything is looked up or written', () => {
  const fx = setup({ claim: false });
  for (const args of [['--tasks', 'unknown-task', '--apply'], ['--tasks', '', '--apply'], ['--tasks'], ['--tasks', 'npm-verify,'],
    ['--tasks', 'npm-verify,npm-verify'], ['--apply', '--dry-run'], ['--bogus'], ['--tasks', 'npm-verify;rm', '--apply']]) {
    const r = run(fx, [...args, '--json']);
    assert.equal(r.status, 2, `${args.join(' ')}: ${r.stdout}${r.stderr}`);
    const d = one(r.stdout);
    assert.equal(d.status, 'error');
    assert.equal(d.tasks.length, 0);
    assert.equal(run(fx, ['--check', ...args]).status, 2);
  }
  assert.equal(run(fx, ['--check', '--apply', '--tasks', 'uv-prune']).status, 0);
  assert.deepEqual(calls(fx), []);
  assert.equal(fs.existsSync(fx.aicm), false);
});

test('apply runs exactly the allowlisted commands with download guards, then releases the lock', () => {
  const fx = setup();
  const r = run(fx, ['--apply', '--json']);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const d = one(r.stdout);
  assert.equal(d.status, 'ok');
  assert.equal(d.summary.succeeded, 3);
  const seen = calls(fx);
  assert.deepEqual(seen.map((c) => [c.name, ...c.args]), [['npm', 'cache', 'verify'], ['uv', 'cache', 'prune'], ['pnpm', 'store', 'prune']]);
  for (const c of seen) {
    assert.equal(c.env.COREPACK_ENABLE_NETWORK, '0');
    assert.equal(c.env.COREPACK_ENABLE_DOWNLOAD_PROMPT, '0');
    assert.equal(c.env.npm_config_offline, 'true');
    assert.equal(c.env.UV_OFFLINE, '1');
    assert.equal(c.env.AICM_MAINTENANCE_LEASE, null, 'the lease is not handed to a vendor tool');
  }
  assert.equal(fs.existsSync(path.join(fx.aicm, 'state', 'maintenance.lock')), false, 'lock released');
  const sel = setup();
  assert.equal(run(sel, ['--apply', '--tasks', 'uv-prune', '--json']).status, 0);
  assert.deepEqual(calls(sel).map((c) => c.name), ['uv']);
});

test('a folder with spaces and shell characters is passed as one path, never interpreted', () => {
  const name = WIN ? 'fake bin (x86)' : 'fake bin $(touch INJECTED); `touch INJECTED2` & |';
  const fx = setup({ binName: WIN ? 'fake bin' : name });
  const r = run(fx, ['--apply', '--tasks', 'npm-verify', '--json'], { });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.deepEqual(calls(fx).map((c) => [c.name, ...c.args]), [['npm', 'cache', 'verify']]);
  assert.equal(fs.existsSync(path.join(fx.dir, 'INJECTED')), false);
  assert.equal(fs.existsSync(path.join(process.cwd(), 'INJECTED')), false);
  assert.equal(fs.existsSync(path.join(process.cwd(), 'INJECTED2')), false);
  if (WIN) {
    // A batch shim under a folder with cmd.exe metacharacters is refused, not run.
    const bad = setup({ binName: name });
    const b = run(bad, ['--apply', '--tasks', 'npm-verify', '--json']);
    assert.equal(b.status, 1);
    assert.equal(one(b.stdout).tasks[0].status, 'refused');
    assert.deepEqual(calls(bad), []);
  }
});

test('a running package manager skips its task; an unreadable process table skips every task', () => {
  const fx = setup();
  fs.writeFileSync(fx.procs, JSON.stringify([
    { pid: 1, ppid: 0, name: 'init', cmd: '/sbin/init' },
    { pid: 999991, ppid: 1, name: 'node', cmd: 'node /usr/lib/node_modules/npm/bin/npm-cli.js install' },
  ]));
  const r = run(fx, ['--apply', '--json']);
  assert.equal(r.status, 1);
  const d = one(r.stdout);
  assert.equal(d.tasks[0].status, 'busy');
  assert.match(d.tasks[0].reason, /999991/);
  assert.deepEqual(calls(fx).map((c) => c.name), ['uv', 'pnpm']);

  const gone = setup();
  for (const list of [path.join(gone.dir, 'missing.json'), null]) {
    if (list === null) fs.writeFileSync(gone.procs, '[]');
    const g = run(gone, ['--apply', '--json'], list ? { AICM_PROCESS_LIST: list } : {});
    assert.equal(g.status, 1);
    const gd = one(g.stdout);
    assert.ok(gd.tasks.every((t) => t.status === 'skipped' && /process table unavailable/.test(t.reason)), g.stdout);
  }
  assert.deepEqual(calls(gone), []);
});

test('the busy check ignores this optimizer but retains package-manager ancestors', () => {
  const list = [
    { pid: 10, ppid: 1, name: 'node', cmd: 'node /x/npm/bin/npm-cli.js exec aicm' },
    { pid: 11, ppid: 10, name: 'bash', cmd: 'bash bin/aicm optimize --apply' },
    { pid: process.pid, ppid: 11, name: 'node', cmd: 'node lib/optimize.js --apply' },
    { pid: 20, ppid: 1, name: 'pnpm.exe', cmd: '"C:\\Program Files\\pnpm\\pnpm.exe" install' },
    { pid: 21, ppid: 1, name: 'uv', cmd: '/home/u/.local/bin/uv run app.py' },
    { pid: 22, ppid: 1, name: 'node', cmd: 'node C:\\npm\\node_modules\\npm\\bin\\npx-cli.js cowsay' },
    { pid: 23, ppid: 1, name: 'vim', cmd: 'vim npm-notes.txt' },
  ];
  const fakePpid = Object.getOwnPropertyDescriptor(process, 'ppid');
  Object.defineProperty(process, 'ppid', { value: 11, configurable: true });
  let mine;
  try { mine = opt.ownChain(list); } finally { Object.defineProperty(process, 'ppid', fakePpid); }
  assert.ok(mine.has(10) && mine.has(11) && mine.has(process.pid));
  const npm = opt.TASKS.find((t) => t.id === 'npm-verify');
  assert.deepEqual(opt.busyPids(npm, list, mine), [10, 22]);
  assert.deepEqual(opt.busyPids(opt.TASKS.find((t) => t.id === 'pnpm-prune'), list, mine), [20]);
  assert.deepEqual(opt.busyPids(opt.TASKS.find((t) => t.id === 'uv-prune'), list, mine), [21]);
});

test('a failing task is a failure, the others still run', () => {
  const fx = setup();
  const r = run(fx, ['--apply', '--json'], { FAKE_OPTIMIZE_UV: 'fail' });
  assert.equal(r.status, 1);
  const d = one(r.stdout);
  assert.deepEqual(d.tasks.map((t) => t.status), ['ok', 'failed', 'ok']);
  assert.equal(d.tasks[1].exitCode, 3);
  assert.match(d.tasks[1].output, /simulated failure/);
  assert.equal(d.summary.failed, 1);
  assert.equal(d.status, 'partial');
  assert.equal(fs.existsSync(path.join(fx.aicm, 'state', 'maintenance.lock')), false, 'lock released after a failure');
});

test('a hanging task times out, its process tree is stopped and it is not a success', () => {
  const fx = setup();
  const r = run(fx, ['--apply', '--tasks', 'npm-verify,uv-prune', '--json'], { FAKE_OPTIMIZE_NPM: 'hang', AICM_OPTIMIZE_TIMEOUT: '8' });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  const d = one(r.stdout);
  assert.equal(d.tasks[0].status, 'timeout');
  assert.equal(d.tasks[1].status, 'ok', 'the next task still runs');
  const pid = Number(fs.readFileSync(path.join(fx.dir, 'grandchild.pid'), 'utf8'));
  let alive = true;
  for (let i = 0; i < 50 && alive; i++) {
    try { process.kill(pid, 0); spawnSync(process.execPath, ['-e', 'setTimeout(()=>{},100)']); } catch { alive = false; }
  }
  assert.equal(alive, false, 'the grandchild was stopped with its parent');
  assert.equal(fs.existsSync(path.join(fx.aicm, 'state', 'maintenance.lock')), false);
});

test('apply refuses an unclaimed home and a held maintenance lock', () => {
  const fx = setup({ claim: false });
  fs.mkdirSync(fx.aicm, { recursive: true });
  const r = run(fx, ['--apply', '--json']);
  assert.equal(r.status, 1);
  assert.equal(one(r.stdout).status, 'refused');
  assert.deepEqual(calls(fx), []);

  const held = setup();
  const lock = path.join(held.aicm, 'state', 'maintenance.lock');
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString(), lease: 'a'.repeat(64) }));
  const h = run(held, ['--apply', '--json']);
  assert.equal(h.status, 1);
  const d = one(h.stdout);
  assert.equal(d.status, 'refused');
  assert.match(d.errors[0], /maintenance lock/);
  assert.ok(d.tasks.every((t) => t.status === 'skipped'));
  assert.deepEqual(calls(held), []);
  assert.ok(fs.existsSync(path.join(lock, 'owner.json')), 'a lock held by another run is left alone');

  const ref = run(held, ['--refuse', 'an update run is in progress (pid 7)', '--apply', '--json']);
  assert.equal(ref.status, 1);
  assert.deepEqual(one(ref.stdout).errors, ['an update run is in progress (pid 7)']);
});

test('Windows launch rules: quoted cmd.exe call, metacharacters and scripts refused', () => {
  const env = { SystemRoot: 'C:\\Windows' };
  const s = opt.launchSpec('C:\\Program Files\\nodejs\\npm.cmd', ['cache', 'verify'], env, true);
  assert.equal(s.file, 'C:\\Windows\\System32\\cmd.exe');
  assert.deepEqual(s.args, ['/d', '/v:off', '/s', '/c', '""C:\\Program Files\\nodejs\\npm.cmd" cache verify"']);
  assert.equal(s.verbatim, true);
  for (const bad of ['C:\\a&b\\npm.cmd', 'C:\\100%\\npm.cmd', 'C:\\x!y\\npm.bat', 'C:\\q"\\npm.cmd', 'C:\\a^b\\npm.cmd', 'C:\\(x)\\npm.cmd']) {
    assert.ok(opt.launchSpec(bad, ['cache', 'verify'], env, true).refused, bad);
  }
  assert.ok(opt.launchSpec('C:\\tools\\pnpm.ps1', ['store', 'prune'], env, true).refused);
  assert.ok(opt.launchSpec('C:\\tools\\npm.cmd', ['cache', 'verify'], { SystemRoot: 'C:\\W&x' }, true).refused);
  assert.deepEqual(opt.launchSpec('C:\\uv\\uv.exe', ['cache', 'prune'], env, true), { file: 'C:\\uv\\uv.exe', args: ['cache', 'prune'], verbatim: false });
  assert.deepEqual(opt.launchSpec('/usr/bin/npm', ['cache', 'verify'], env, false), { file: '/usr/bin/npm', args: ['cache', 'verify'], verbatim: false });
});

test('tool lookup trusts only absolute PATH entries and (on Unix) executable files', () => {
  const fx = setup({ tools: [] });
  const sub = path.join(fx.dir, 'rel');
  fs.mkdirSync(sub);
  const p = path.join(sub, WIN ? 'npm.cmd' : 'npm');
  fs.writeFileSync(p, 'x');
  if (!WIN) fs.chmodSync(p, 0o755);
  const cwd = process.cwd();
  process.chdir(fx.dir);
  try {
    assert.equal(opt.resolveTool('npm', { PATH: 'rel', PATHEXT: '.CMD' }, WIN), null, 'relative PATH entries are skipped');
  } finally { process.chdir(cwd); }
  assert.equal(opt.resolveTool('npm', { PATH: sub, PATHEXT: '.CMD' }, WIN), p);
  if (!WIN) {
    fs.chmodSync(p, 0o644);
    assert.equal(opt.resolveTool('npm', { PATH: sub }, false), null, 'a file without execute permission is not a tool');
  }
});

test('the task table is the fixed allowlist', () => {
  assert.deepEqual(opt.TASKS.map((t) => [t.id, t.tool, ...t.args]), [
    ['npm-verify', 'npm', 'cache', 'verify'], ['uv-prune', 'uv', 'cache', 'prune'], ['pnpm-prune', 'pnpm', 'store', 'prune']]);
  const src = fs.readFileSync(js, 'utf8');
  assert.doesNotMatch(src, /shell:\s*true/);
  assert.doesNotMatch(src, /\beval\(|\bexecSync\(|\bexecFile|new Function/);
  assert.deepEqual(src.match(/require\('child_process'\)/g), ["require('child_process')"]);
  assert.match(src, /const \{ spawn, spawnSync \} = require\('child_process'\);/);
});
