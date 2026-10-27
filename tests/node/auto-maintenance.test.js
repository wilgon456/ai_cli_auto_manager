'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const files = require('../../lib/maintenance-files');
const { choose, scan } = require('../../lib/maintenance-processes');
const { options, versionWarnings, run } = require('../../lib/auto-maintenance');
const { birth } = require('../../lib/supervise');
const DAY = 86400000, SESSION = 'abcdefab-1234-1234-1234-abcdefabcdef';
const opts = { uid: 1000, platform: 'linux', selfPid: 9999 };
const proc = (extra = {}) => ({ pid: 100, ppid: 1, pgid: 100, uid: 1000, elevated: false, created: 'start', ageSec: 7 * 3600, name: 'node', cmd: 'node server.js', listening: true, ...extra });
function fixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-maintenance-')));
  const home = path.join(root, 'home'), aicmHome = path.join(home, '.ai-cli-auto-manager');
  fs.mkdirSync(aicmHome, { recursive: true });
  fs.writeFileSync(path.join(aicmHome, '.aicm-home'), 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n');
  return { root, home, aicmHome, temp: root };
}
const empty = { snapshot: () => ({ uid: 1000, procs: [] }) };

test('dry-run wins, config arguments validated and floor warns without updating', () => {
  assert.equal(options([]).apply, false);
  assert.equal(options(['--dry-run', '--apply']).apply, false);
  assert.throws(() => options(['--config']), /needs a path/);
  assert.throws(() => options(['--bogus']), /Unknown/);
  assert.equal(versionWarnings({ clis: [{ id: 'claude', version: '2.1.282' }] }).length, 1);
  assert.equal(versionWarnings({ clis: [{ id: 'claude', version: '2.1.283-beta.1' }] }).length, 1);
  assert.equal(versionWarnings({ clis: [{ id: 'claude', version: '2.1.283' }] }).length, 0);
  assert.equal(versionWarnings({ clis: [{ id: 'claude', version: '2.1.300+build' }] }).length, 0);
});

test('only tagged orphans may end; untagged listener is alert-only even on apply', async () => {
  const list = [proc({ session: SESSION }), proc({ pid: 200, pgid: 200 }), proc({ pid: 300, pgid: 300, ageSec: 21599 }), proc({ pid: 400, pgid: 400, listening: false })];
  assert.deepEqual(choose(list, new Map(), opts).map((p) => [p.pid, p.action]), [[100, 'end'], [200, 'alert']]);
  const killed = [], actions = [];
  await scan({ aicmHome: '/does-not-exist' }, { apply: true }, (a) => actions.push(a), { snapshot: () => ({ uid: 1000, procs: list }), sessions: new Map(), kill: async (p) => killed.push(p.pid) });
  assert.deepEqual(killed, [100]);
  assert.equal(actions.find((a) => a.pid === 200).action, 'alert');
});

test('active sessions, daemons, remote sessions, elevation, other users and unknown age are protected', () => {
  for (const patch of [{ uid: 0 }, { elevated: true }, { elevated: undefined }, { uid: undefined }, { ageSec: null }, { cmd: 'paseo daemon' }, { cmd: 'codex app-server' }, { cmd: 'ssh host' }]) {
    assert.equal(choose([proc({ session: SESSION, ...patch })], new Map(), opts).length, 0);
  }
  const owner = proc({ pid: 500, ppid: 1, pgid: 500, created: 'owner', ageSec: 99999, listening: false, name: 'bash', cmd: 'bash' });
  const records = new Map([[SESSION, { ownerPid: 500, ownerCreated: 'owner' }]]);
  assert.equal(choose([owner, proc({ session: SESSION })], records, opts).length, 0, 'live session even if child reparented');
  const remote = { ...owner, cmd: 'sshd: user' };
  assert.equal(choose([remote, proc({ session: SESSION, ppid: 500 })], new Map(), opts).length, 0);
  assert.equal(choose([proc({ session: SESSION, pgid: 9999 }), proc({ pid: 9999, pgid: 9999 })], new Map(), opts).some((d) => d.action === 'end'), false);
});

test('mixed groups alert, PID reuse and changed tree prevent signaling', async () => {
  const a = proc({ session: SESSION }), b = proc({ pid: 101, session: undefined });
  assert.equal(choose([a, b], new Map(), opts)[0].action, 'alert');
  let calls = 0, kills = 0; const actions = [];
  await scan({ aicmHome: '/missing' }, { apply: true }, (a) => actions.push(a), {
    sessions: new Map(), snapshot: () => ({ uid: 1000, procs: [{ ...a, created: calls++ ? 'reused' : 'start' }] }), kill: async () => { kills++; },
  });
  assert.equal(kills, 0); assert.equal(actions[0].action, 'skip');
});

test('Windows tagged trees require verified ownership and protect untagged descendants', () => {
  const windows = { ...opts, platform: 'win32' };
  const p = proc({ session: SESSION, pgid: undefined });
  assert.equal(choose([p], new Map(), windows)[0].action, 'end');
  assert.equal(choose([p, proc({ pid: 101, ppid: 100, session: undefined })], new Map(), windows).some((d) => d.action === 'end'), false);
});

test('rules reject broad roots, too-young ages, relative paths and manager state overlap', () => {
  const c = fixture();
  try {
    for (const p of [c.home, '/', c.aicmHome, path.join(c.aicmHome, 'state'), path.join(c.home, 'memory')]) assert.throws(() => files.parseRules(`x | ${p} | 2 |`, c));
    assert.throws(() => files.parseRules('x | ./temp | 2 |', c));
    assert.throws(() => files.parseRules('x | {aicm}/tmp | 1 |', c));
    const r = files.parseRules('x | {aicm}/tmp | 2 | *.lock,keep/**', c)[0];
    assert.equal(r.root, path.join(c.aicmHome, 'tmp')); assert.equal(r.excludes.length, 2);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('quarantine is reversible, excludes/protected files/links kept, retention uses quarantine time', { timeout: 60000 }, async () => {
  const c = fixture();
  try {
    const dir = path.join(c.aicmHome, 'tmp'); fs.mkdirSync(dir);
    for (const f of ['old.tmp', 'fresh.tmp', '.env', 'MEMORY.md', 'settings.json', 'keep.lock']) fs.writeFileSync(path.join(dir, f), 'data');
    fs.mkdirSync(path.join(dir, 'keep')); fs.writeFileSync(path.join(dir, 'keep', 'old.tmp'), 'kept');
    const now = Date.now() + 3 * DAY;
    fs.utimesSync(path.join(dir, 'fresh.tmp'), new Date(now), new Date(now));
    if (process.platform !== 'win32') fs.symlinkSync(path.join(dir, 'old.tmp'), path.join(dir, 'link'));
    const preview = await run(c, { files: true, processes: false, now });
    // Missing lsof intentionally keeps everything rather than assuming files are unlocked.
    const canCheck = process.platform === 'win32' || spawnSync('lsof', ['-v'], { encoding: 'utf8' }).status === 0;
    if (!canCheck) { assert.equal(preview.actions.some((a) => a.action === 'would-quarantine'), false); return; }
    assert.equal(preview.actions.filter((a) => a.action === 'would-quarantine').length, 1);
    assert.ok(fs.existsSync(path.join(dir, 'old.tmp')));
    const apply = await run(c, { files: true, processes: false, apply: true, now });
    const moved = apply.actions.find((a) => a.action === 'quarantine'); assert.ok(moved);
    assert.equal(fs.existsSync(path.join(dir, 'old.tmp')), false);
    assert.equal(fs.readFileSync(path.join(moved.quarantine, 'payload'), 'utf8'), 'data');
    assert.equal(JSON.parse(fs.readFileSync(path.join(moved.quarantine, 'manifest.json'))).source, path.join(dir, 'old.tmp'));
    for (const f of ['.env', 'MEMORY.md', 'settings.json', 'keep.lock', 'fresh.tmp', 'keep/old.tmp']) assert.ok(fs.existsSync(path.join(dir, f)));
    await run(c, { files: true, processes: false, apply: true, now: now + 6 * DAY });
    assert.ok(fs.existsSync(moved.quarantine));
    const purge = await run(c, { files: true, processes: false, apply: true, now: now + 7 * DAY + 1 });
    assert.ok(purge.actions.some((a) => a.action === 'purge')); assert.equal(fs.existsSync(moved.quarantine), false);
    const logFile = path.join(c.aicmHome, 'logs', `maintenance-${new Date(now).toISOString().slice(0, 10)}.jsonl`);
    for (const line of fs.readFileSync(logFile, 'utf8').trim().split('\n')) assert.ok(JSON.parse(line).reason);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('open files stay, backwards clock withholds files, summaries accumulate, lock excludes concurrent runs', async () => {
  const c = fixture(); let fd;
  try {
    fs.mkdirSync(path.join(c.aicmHome, 'tmp')); const f = path.join(c.aicmHome, 'tmp', 'open.tmp'); fs.writeFileSync(f, 'open'); fd = fs.openSync(f, 'r');
    const now = Date.now() + 3 * DAY;
    const first = await run(c, { files: true, processes: false, apply: true, now }, empty);
    assert.ok(fs.existsSync(f)); assert.ok(first.actions.some((a) => a.action === 'skip'));
    const second = await run(c, { files: true, processes: false, apply: true, now: now - DAY }, empty);
    assert.ok(second.actions.some((a) => /clock/.test(a.reason)));
    const third = await run(c, { files: false, processes: true, now }, empty); assert.match(third.summary, /2 run/);
    const lock = path.join(c.aicmHome, 'state', 'maintenance.lock'); fs.writeFileSync(lock, '{}');
    await assert.rejects(run(c, { files: false, processes: false }), /already running/);
  } finally { if (fd !== undefined) fs.closeSync(fd); fs.rmSync(c.root, { recursive: true, force: true }); }
});

async function waitFor(check, timeout = 10000) {
  const end = Date.now() + timeout;
  while (!check()) { if (Date.now() > end) throw new Error('condition timed out'); await new Promise((r) => setTimeout(r, 50)); }
}
function live(pid) { return Boolean(birth(pid)); }
const supervisor = path.resolve(__dirname, '../../lib/supervise.js');
test('Unix guardian contains grandchildren on exit, timeout, launcher SIGKILL and parent death', { skip: process.platform === 'win32', timeout: 45000 }, async () => {
  for (const mode of ['normal', 'timeout', 'kill', 'parent']) {
    const c = fixture(); let launcher, grandPid;
    try {
      const file = path.join(c.root, 'pids.json');
      const program = `const {spawn}=require('child_process'); const fs=require('fs'); const c=spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],{stdio:'ignore'}); fs.writeFileSync(${JSON.stringify(file)},JSON.stringify({pid:c.pid,root:process.pid,tag:process.env.AI_CLI_MANAGER_SESSION})); ${mode === 'normal' ? 'setTimeout(()=>process.exit(0),300)' : 'setInterval(()=>{},1000)'};`;
      const args = [supervisor, '--timeout', mode === 'timeout' ? '1' : '0', '--', process.execPath, '-e', program];
      const parentArgs = ['-e', `require('child_process').spawn(process.execPath,${JSON.stringify(args)},{stdio:'ignore'});setInterval(()=>{},1000)`];
      launcher = spawn(process.execPath, mode === 'parent' ? parentArgs : args, { env: { ...process.env, HOME: c.home, AICM_HOME: c.aicmHome }, stdio: 'ignore' });
      const exited = new Promise((r) => launcher.once('exit', (code) => r(code)));
      await waitFor(() => fs.existsSync(file));
      const pids = JSON.parse(fs.readFileSync(file)); grandPid = pids.pid;
      assert.match(pids.tag, /^[a-f0-9-]{36}$/); assert.ok(live(grandPid));
      if (mode === 'kill' || mode === 'parent') launcher.kill('SIGKILL');
      const code = await exited;
      if (mode === 'timeout') assert.equal(code, 124);
      if (mode === 'normal') assert.equal(code, 0);
      await waitFor(() => !live(grandPid));
    } finally {
      if (launcher && live(launcher.pid)) launcher.kill('SIGKILL');
      if (grandPid && live(grandPid)) process.kill(grandPid, 'SIGKILL');
      fs.rmSync(c.root, { recursive: true, force: true });
    }
  }
});

test('CLI emits one JSON document and reads a PowerShell BOM inventory for version floors', () => {
  const c = fixture();
  try {
    fs.mkdirSync(path.join(c.aicmHome, 'state'));
    fs.writeFileSync(path.join(c.aicmHome, 'state', 'inventory.json'), '\uFEFF' + JSON.stringify({ clis: [{ id: 'claude', version: '2.1.282' }] }));
    const cli = path.resolve(__dirname, '../../lib/auto-maintenance.js');
    const r = spawnSync(process.execPath, [cli, '--files-only', '--apply', '--dry-run', '--json'], { encoding: 'utf8', env: { ...process.env, HOME: c.home, USERPROFILE: c.home, AICM_HOME: c.aicmHome } });
    assert.equal(r.status, 0, r.stderr);
    const result = JSON.parse(r.stdout);
    assert.equal(result.dryRun, true);
    assert.ok(result.actions.some((a) => a.cli === 'claude' && a.action === 'alert'));
    assert.equal(fs.existsSync(path.join(c.aicmHome, 'state', 'maintenance.lock')), false);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});

test('injected CLI process snapshots can never authorize real mutations', () => {
  const c = fixture();
  try {
    const list = path.join(c.root, 'processes.json');
    fs.writeFileSync(list, JSON.stringify([proc({ session: SESSION })]));
    const cli = path.resolve(__dirname, '../../lib/auto-maintenance.js');
    const r = spawnSync(process.execPath, [cli, '--processes-only', '--apply', '--json'], { encoding: 'utf8', env: { ...process.env, HOME: c.home, USERPROFILE: c.home, AICM_HOME: c.aicmHome, AICM_PROCESS_LIST: list } });
    assert.equal(r.status, 0, r.stderr);
    const result = JSON.parse(r.stdout);
    assert.equal(result.dryRun, true);
    assert.ok(result.actions.some((a) => a.action === 'would-end'));
    assert.equal(result.actions.some((a) => a.action === 'end'), false);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});


test('direct automatic maintenance refuses an unmanaged home before writing audit or session state', () => {
  const c = fixture();
  try {
    fs.unlinkSync(path.join(c.aicmHome, '.aicm-home'));
    fs.writeFileSync(path.join(c.aicmHome, 'personal.txt'), 'keep');
    const cli = path.resolve(__dirname, '../../lib/auto-maintenance.js');
    const r = spawnSync(process.execPath, [cli, '--files-only', '--dry-run', '--json'], { encoding: 'utf8', env: { ...process.env, HOME: c.home, USERPROFILE: c.home, AICM_HOME: c.aicmHome } });
    assert.notEqual(r.status, 0);
    assert.deepEqual(fs.readdirSync(c.aicmHome), ['personal.txt']);
  } finally { fs.rmSync(c.root, { recursive: true, force: true }); }
});


test('automatic maintenance shares the archive/restore/cleanup lease and preserves a live owner', async () => {
  const c = fixture();
  const maintenance = require('../../lib/maintenance');
  const lease = maintenance.acquireLock(c.aicmHome, { contextHome: c.aicmHome });
  try {
    await assert.rejects(run(c, { files: false, processes: false }, empty), /already running/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(lease.dir, 'owner.json'), 'utf8')).pid, process.pid);
  } finally { lease.release(); fs.rmSync(c.root, { recursive: true, force: true }); }
});
