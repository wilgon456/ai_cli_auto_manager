'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'lib/maintenance-cli.js');

function setup() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-mcli-'));
  const home = path.join(dir, 'user');
  const aicm = path.join(home, '.ai-cli-auto-manager');
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(aicm, { recursive: true });
  const env = { ...process.env, HOME: home, USERPROFILE: home, AICM_HOME: aicm, AICM_WORKTREES: '0' };
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  process.env.AICM_HOME = aicm;
  return { dir, home, aicm, env };
}

function run(env, args) {
  return spawnSync(process.execPath, [cli, ...args], { env, encoding: 'utf8' });
}

test('archive list, dry restore, conflict, restore and history', () => {
  const fx = setup();
  const srcDir = path.join(fx.home, 'notes');
  fs.mkdirSync(srcDir);
  const src = path.join(srcDir, 'a.txt');
  fs.writeFileSync(src, 'hello');
  const api = require(path.join(root, 'lib/maintenance.js'));
  const day = '20200102';
  const dest = path.join(fx.aicm, 'archive', 'demo-rule', day, 'a.txt');
  const put = api.archivePut({ rule: 'demo-rule', root: srcDir, source: src, dest });
  assert.equal(put.ok, true, put.error);
  assert.equal(fs.existsSync(src), false);

  const listed = run(fx.env, ['archive', 'list', '--json']);
  assert.equal(listed.status, 0, listed.stderr);
  const doc = JSON.parse(listed.stdout);
  assert.equal(doc.items.some((i) => i.id === put.id), true);

  const dry = run(fx.env, ['restore', put.id, '--dry-run', '--json']);
  assert.equal(dry.status, 0, dry.stderr);
  assert.equal(JSON.parse(dry.stdout).dryRun, true);
  assert.equal(fs.existsSync(src), false);

  fs.mkdirSync(srcDir, { recursive: true });
  fs.writeFileSync(src, 'busy');
  const clash = run(fx.env, ['restore', put.id, '--json']);
  assert.notEqual(clash.status, 0);
  assert.equal(JSON.parse(clash.stdout).status, 'conflict');
  assert.equal(fs.readFileSync(src, 'utf8'), 'busy');

  fs.unlinkSync(src);
  const back = run(fx.env, ['restore', put.id]);
  assert.equal(back.status, 0, back.stderr);
  assert.equal(fs.readFileSync(src, 'utf8'), 'hello');

  const hist = run(fx.env, ['history', '--json']);
  assert.equal(hist.status, 0, hist.stderr);
  const items = JSON.parse(hist.stdout).items;
  assert.equal(items.some((i) => i.kind === 'restore'), true);
  assert.equal(items.some((i) => String(i.summary || '').includes('hello') || JSON.stringify(i).includes('hello')), false);
  const human = run(fx.env, ['history']);
  assert.equal(human.status, 0, human.stderr);
  assert.match(human.stdout, /restore .+ restored=1 conflict=0 error=0/);
  assert.equal(human.stdout.includes('hello'), false);
  fs.rmSync(fx.dir, { recursive: true, force: true });
});

test('restore dry-run never writes history, including invalid id and conflict', () => {
  const fx = setup();
  const state = path.join(fx.aicm, 'state');
  const bad = run(fx.env, ['restore', 'not a valid', '--dry-run', '--json']);
  assert.notEqual(bad.status, 0);
  assert.equal(JSON.parse(bad.stdout).ok, false);
  assert.equal(fs.existsSync(state), false);

  const api = require(path.join(root, 'lib/maintenance.js'));
  const srcDir = path.join(fx.home, 'notes');
  fs.mkdirSync(srcDir);
  const src = path.join(srcDir, 'a.txt');
  fs.writeFileSync(src, 'hello');
  const put = api.archivePut({ rule: 'demo-rule', root: srcDir, source: src, dest: path.join(fx.aicm, 'archive', 'demo-rule', '20200102', 'a.txt') });
  assert.equal(put.ok, true, put.error);
  fs.mkdirSync(srcDir, { recursive: true });
  fs.writeFileSync(src, 'busy');
  const histDir = path.join(state, 'history');
  const before = fs.existsSync(histDir) ? fs.readdirSync(histDir).sort() : [];
  const stateBefore = fs.readdirSync(state).sort();
  const dry = run(fx.env, ['restore', put.id, '--dry-run', '--json']);
  assert.notEqual(dry.status, 0);
  assert.equal(JSON.parse(dry.stdout).status, 'conflict');
  assert.equal(JSON.parse(dry.stdout).dryRun, undefined);
  const after = fs.existsSync(histDir) ? fs.readdirSync(histDir).sort() : [];
  assert.deepEqual(after, before);
  assert.deepEqual(fs.readdirSync(state).sort(), stateBefore);
  assert.equal(fs.readFileSync(src, 'utf8'), 'busy');

  const failed = run(fx.env, ['restore', put.id, '--json']);
  assert.notEqual(failed.status, 0);
  assert.equal(JSON.parse(failed.stdout).status, 'conflict');
  const hist = run(fx.env, ['history', '--json']);
  const items = JSON.parse(hist.stdout).items.filter((i) => i.kind === 'restore');
  assert.equal(items.length, 1);
  assert.equal(items[0].ok, false);
  assert.equal(items[0].summary.conflicts, 1);
  assert.equal(items[0].results[0].id, put.id);
  assert.equal(JSON.stringify(items).includes('busy'), false);
  assert.equal(JSON.stringify(items).includes('hello'), false);
  const text = run(fx.env, ['history']);
  assert.match(text.stdout, new RegExp(`restore ${items[0].id} restored=0 conflict=1 error=1`));
  fs.rmSync(fx.dir, { recursive: true, force: true });
});

test('human history prints clean and update counts', () => {
  const fx = setup();
  const api = require(path.join(root, 'lib/maintenance.js'));
  const clean = api.historyAdd('clean', {
    finishedAt: '2020-03-01T00:00:00.000Z',
    summary: { freedBytes: 4, archivedBytes: 6 },
    results: [],
  });
  const update = api.historyAdd('update', {
    finishedAt: '2020-03-02T00:00:00.000Z',
    results: [{ id: 'claude', status: 'verifyFailed' }, { id: 'codex', status: 'updateFailed' }],
  });
  assert.equal(clean.ok, true, clean.error);
  assert.equal(update.ok, true, update.error);
  const human = run(fx.env, ['history']);
  assert.match(human.stdout, /clean .+ freed=4 archived=6/);
  assert.match(human.stdout, /update .+ updateFailed=1 verifyFailed=1/);
  const json = JSON.parse(run(fx.env, ['history', '--json']).stdout);
  assert.equal(json.items.some((i) => i.summary && i.summary.freedBytes === 4), true);
  assert.equal(json.items.some((i) => Object.prototype.hasOwnProperty.call(i, 'line')), false);
  fs.rmSync(fx.dir, { recursive: true, force: true });
});

test('unicode archive filename stays ASCII on stdout and restores exactly', () => {
  const fx = setup();
  const api = require(path.join(root, 'lib/maintenance.js'));
  const srcDir = path.join(fx.home, 'notes');
  fs.mkdirSync(srcDir);
  const name = '\uD55C\uAE00\uD83D\uDE00.txt';
  const src = path.join(srcDir, name);
  const body = 'unicode-body-not-in-json';
  fs.writeFileSync(src, body);
  const put = api.archivePut({
    rule: 'demo-rule',
    root: srcDir,
    source: src,
    dest: path.join(fx.aicm, 'archive', 'demo-rule', '20200102', name),
  });
  assert.equal(put.ok, true, put.error);
  const assertAscii = (text, label) => {
    assert.equal(/[^\x00-\x7f]/.test(text), false, label);
  };
  const listed = run(fx.env, ['archive', 'list', '--json']);
  assert.equal(listed.status, 0, listed.stderr);
  assertAscii(listed.stdout, 'list stdout');
  const doc = JSON.parse(listed.stdout);
  const item = doc.items.find((i) => i.id === put.id);
  assert.equal(item.original, src);
  assert.equal(listed.stdout.includes(body), false);
  const dry = run(fx.env, ['restore', put.id, '--dry-run', '--json']);
  assert.equal(dry.status, 0, dry.stderr);
  assertAscii(dry.stdout, 'dry restore stdout');
  assert.equal(JSON.parse(dry.stdout).original, src);
  assert.equal(dry.stdout.includes(body), false);
  const back = run(fx.env, ['restore', put.id, '--json']);
  assert.equal(back.status, 0, back.stderr);
  assertAscii(back.stdout, 'restore stdout');
  assert.equal(JSON.parse(back.stdout).original, src);
  assert.equal(back.stdout.includes(body), false);
  assert.equal(fs.readFileSync(src, 'utf8'), body);
  const hist = run(fx.env, ['history', '--json']);
  assert.equal(hist.status, 0, hist.stderr);
  assertAscii(hist.stdout, 'history stdout');
  const row = JSON.parse(hist.stdout).items.find((i) => i.kind === 'restore');
  assert.equal(row.results[0].path, src);
  assert.equal(hist.stdout.includes(body), false);
  const manifest = fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${put.id}.json`));
  assert.ok(manifest.includes(Buffer.from(name, 'utf8')));
  assert.equal(manifest.includes(Buffer.from('\\uD55C')), false);
  assert.equal(manifest.includes(Buffer.from(body, 'utf8')), false);
  fs.rmSync(fx.dir, { recursive: true, force: true });
});
