'use strict';
// Archive index at scale: listing is newest first and paged, a truncated index never turns indexed files
// into "legacy", and archive-gc drops only records that can never be restored again. Disposable HOME only.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'maintenance.js');
const CLI = path.join(__dirname, '..', '..', 'lib', 'maintenance-cli.js');
const m = require(MODULE);
const DAY = 86400000;
const KEYS = ['HOME', 'USERPROFILE', 'AICM_HOME', 'TMPDIR', 'TEMP', 'TMP', 'AICM_ARCHIVE_SCAN_LIMIT', 'AICM_ARCHIVE_WALK_LIMIT',
  'AICM_MAINTENANCE_LEASE', 'AICM_MAINTENANCE_OWNER'];

function fresh() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-idx-'));
  const home = path.join(work, 'home');
  const aicm = path.join(home, '.ai-cli-auto-manager');
  fs.mkdirSync(home);
  const env = { HOME: home, USERPROFILE: home, AICM_HOME: aicm, TMPDIR: os.tmpdir(), TEMP: os.tmpdir(), TMP: os.tmpdir() };
  return { work, home, aicm, env, index: path.join(aicm, 'state', 'archive-index') };
}

function withEnv(env, fn) {
  const prev = {};
  for (const k of KEYS) prev[k] = process.env[k];
  for (const k of KEYS) { if (env[k] === undefined) delete process.env[k]; else process.env[k] = env[k]; }
  try { return fn(); } finally {
    for (const k of KEYS) { if (prev[k] === undefined) delete process.env[k]; else process.env[k] = prev[k]; }
  }
}

function writeFile(p, text) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text);
}

// A manifest written the way archive-put writes one, with an id from the given time.
function manifest(fx, when, fields) {
  const id = 'm' + when.toString(16) + crypto.randomBytes(8).toString('hex');
  const record = { id, original: path.join(fx.home, 'proj', `${id}.jsonl`), stored: `demo-rule/20200101/${id}.jsonl`, rule: 'demo-rule',
    archivedAt: new Date(when).toISOString(), size: 1, status: 'archived', ...fields };
  writeFile(path.join(fx.index, `${id}.json`), JSON.stringify(record));
  return record;
}

function today() { return new Date().toISOString().slice(0, 10).replace(/-/g, ''); }

function putActive(fx, name) {
  const root = path.join(fx.home, 'proj');
  const source = path.join(root, name);
  writeFile(source, 'session ' + name);
  const put = m.archivePut({ rule: 'demo-rule', root, source, dest: path.join(fx.aicm, 'archive', 'demo-rule', today(), name) });
  assert.strictEqual(put.ok, true, put.error);
  return put;
}

test('archive index', { concurrency: false }, async (t) => {
  await t.test('10000 expired records plus an active newest one: only true unindexed files are legacy', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const base = Date.now() - 400 * DAY;
      for (let i = 0; i < 10000; i++) manifest(fx, base + i);
      const active = putActive(fx, 'session.jsonl');
      const manual = path.join(fx.aicm, 'archive', 'demo-rule', today(), 'manual.jsonl');
      writeFile(manual, 'copied here by hand');

      const listed = m.archiveList();
      assert.strictEqual(listed.ok, true, listed.error);
      assert.strictEqual(listed.items[0].id, active.id, 'newest record comes first');
      assert.strictEqual(listed.items[0].status, 'archived');
      const legacy = listed.items.filter((i) => i.status === 'legacy').map((i) => i.stored);
      assert.deepStrictEqual(legacy, [`demo-rule/${today()}/manual.jsonl`]);
      assert.ok(!listed.problems.some((p) => /cap|too large/.test(p.error)), JSON.stringify(listed.problems));
      assert.strictEqual(listed.index.total, 10001);
      assert.strictEqual(listed.index.returned, 10000);
      assert.strictEqual(listed.index.nextOffset, 10000);
      assert.strictEqual(listed.index.complete, false);
      assert.deepStrictEqual(listed.legacy, { listed: true, complete: true });

      const next = m.archiveList({ offset: 10000 });
      assert.strictEqual(next.ok, true);
      assert.strictEqual(next.items.length, 1);
      assert.strictEqual(next.items[0].status, 'expired');
      assert.strictEqual(next.index.nextOffset, null);
      assert.strictEqual(next.legacy.listed, false, 'legacy rows come with the first page only');

      const dry = m.restore(active.id, { dryRun: true });
      assert.strictEqual(dry.ok, true, dry.error);

      // Dry run: reports, takes no lock and removes nothing.
      const preview = m.archiveGc({ dryRun: true });
      assert.strictEqual(preview.ok, true, preview.error);
      assert.strictEqual(preview.pruned, 10000);
      assert.strictEqual(preview.reasons.expired, 10000);
      assert.strictEqual(fs.readdirSync(fx.index).length, 10001);
      assert.strictEqual(fs.existsSync(path.join(fx.aicm, 'state', 'maintenance.lock')), false);

      const gc = m.archiveGc();
      assert.strictEqual(gc.ok, true, gc.error);
      assert.strictEqual(gc.pruned, 10000);
      assert.deepStrictEqual(fs.readdirSync(fx.index), [`${active.id}.json`]);
      assert.strictEqual(fs.existsSync(path.join(fx.aicm, 'state', 'maintenance.lock')), false, 'lock released');
      const after = m.archiveList();
      assert.deepStrictEqual(after.items.map((i) => i.status), ['archived', 'legacy']);
      assert.strictEqual(after.index.complete, true);
      const back = m.restore(active.id);
      assert.strictEqual(back.ok, true, back.error);
      assert.strictEqual(fs.readFileSync(path.join(fx.home, 'proj', 'session.jsonl'), 'utf8'), 'session session.jsonl');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('gc keeps every record that may still matter and every unknown file', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const now = Date.now();
      const active = putActive(fx, 'live.jsonl');
      const keep = [
        manifest(fx, now - 300 * DAY, { status: 'pending' }),
        manifest(fx, now - 300 * DAY, { status: 'missing' }),
        manifest(fx, now - 300 * DAY, { status: 'conflict' }),
        // Stored file gone but its dated folder is still there: removed by hand, not by retention.
        manifest(fx, now - 300 * DAY, { stored: `demo-rule/${today()}/gone.jsonl` }),
        // Expired but archived less than a day ago.
        manifest(fx, now - 3600000, { stored: 'demo-rule/20000101/young.jsonl' }),
        // Not a dated layout: never guessed at.
        manifest(fx, now - 300 * DAY, { stored: 'demo-rule/misc/x.jsonl' }),
      ];
      const recentRestored = manifest(fx, now - 300 * DAY, { status: 'restored' });
      const oldRestored = manifest(fx, now - 300 * DAY, { status: 'restored' });
      const oldFile = path.join(fx.index, `${oldRestored.id}.json`);
      fs.utimesSync(oldFile, (now - 40 * DAY) / 1000, (now - 40 * DAY) / 1000);
      const expired = manifest(fx, now - 300 * DAY, {});
      const unknown = ['notes.txt', '.m1.json.1.abcd.tmp', 'zz-broken.json'];
      writeFile(path.join(fx.index, unknown[0]), 'mine');
      writeFile(path.join(fx.index, unknown[1]), '{');
      writeFile(path.join(fx.index, unknown[2]), 'not json');

      const gc = m.archiveGc();
      assert.strictEqual(gc.ok, true, gc.error);
      assert.deepStrictEqual(gc.reasons, { expired: 1, restored: 1 });
      const left = new Set(fs.readdirSync(fx.index));
      for (const r of [active, ...keep, recentRestored]) assert.ok(left.has(`${r.id}.json`), `kept ${r.status} ${r.stored}`);
      assert.ok(!left.has(`${oldRestored.id}.json`));
      assert.ok(!left.has(`${expired.id}.json`));
      for (const name of unknown) assert.ok(left.has(name), `unknown ${name} kept`);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('a truncated index or archive walk lists no legacy guesses and says so', () => {
    const fx = fresh();
    withEnv({ ...fx.env, AICM_ARCHIVE_SCAN_LIMIT: '3' }, () => {
      for (const n of ['a', 'b', 'c', 'd']) putActive(fx, `${n}.jsonl`);
      writeFile(path.join(fx.aicm, 'archive', 'demo-rule', today(), 'manual.jsonl'), 'by hand');
      const listed = m.archiveList();
      assert.strictEqual(listed.ok, true);
      assert.strictEqual(listed.items.filter((i) => i.status === 'legacy').length, 0);
      assert.strictEqual(listed.items.filter((i) => i.status === 'archived').length, 4);
      assert.deepStrictEqual(listed.legacy, { listed: true, complete: false, reason: 'index-too-large' });
      assert.ok(listed.problems.some((p) => /too large/.test(p.error)));
    });
    withEnv({ ...fx.env, AICM_ARCHIVE_WALK_LIMIT: '2' }, () => {
      const listed = m.archiveList();
      assert.strictEqual(listed.legacy.complete, false);
      assert.strictEqual(listed.legacy.reason, 'walk-limit');
      assert.ok(listed.items.filter((i) => i.status === 'legacy').length <= 1);
    });
    withEnv(fx.env, () => {
      const page = m.archiveList({ limit: 2 });
      assert.strictEqual(page.items.filter((i) => i.status === 'archived').length, 2);
      assert.strictEqual(page.index.nextOffset, 2);
      const rest = m.archiveList({ limit: 2, offset: 2 });
      assert.strictEqual(rest.items.length, 2);
      assert.strictEqual(rest.index.nextOffset, null);
      assert.notDeepStrictEqual(page.items.map((i) => i.id), rest.items.map((i) => i.id));
      assert.strictEqual(m.archiveList({ limit: 0 }).status, 'usage');
      assert.strictEqual(m.archiveList({ limit: 10001 }).status, 'usage');
      assert.strictEqual(m.archiveList({ offset: -1 }).status, 'usage');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('user-facing adapter passes paging and gc options and validates them', () => {
    const fx = fresh();
    withEnv(fx.env, () => { putActive(fx, 'a.jsonl'); putActive(fx, 'b.jsonl'); manifest(fx, Date.now() - 300 * DAY, {}); });
    const run = (args) => spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { ...process.env, ...fx.env } });
    let r = run(['archive', 'list', '--limit', '1', '--json']);
    assert.strictEqual(r.status, 0, r.stderr);
    let doc = JSON.parse(r.stdout);
    assert.strictEqual(doc.items.filter((i) => i.status !== 'legacy').length, 1);
    assert.strictEqual(doc.index.nextOffset, 1);
    r = run(['archive', 'list', '--limit', '1']);
    assert.match(r.stdout, /next page: aicm archive list --offset 1/);
    r = run(['archive', 'list', '--offset', '2', '--json']);
    doc = JSON.parse(r.stdout);
    assert.strictEqual(doc.items[0].status, 'expired');
    for (const bad of [['--limit', '0'], ['--limit', 'x'], ['--offset', '-1'], ['--dry-run']]) {
      r = run(['archive', 'list', ...bad]);
      assert.strictEqual(r.status, 2, `${bad.join(' ')}: ${r.stdout}${r.stderr}`);
    }
    r = run(['archive', 'gc', '--dry-run']);
    assert.strictEqual(r.status, 0, r.stderr);
    assert.match(r.stdout, /would drop 1 of 3 records \(1 expired/);
    assert.strictEqual(fs.readdirSync(fx.index).length, 3);
    r = run(['archive', 'gc', '--json']);
    doc = JSON.parse(r.stdout);
    assert.strictEqual(doc.pruned, 1);
    assert.strictEqual(fs.readdirSync(fx.index).length, 2);
    r = run(['archive', 'gc', '--limit', '3']);
    assert.strictEqual(r.status, 2);
    r = spawnSync(process.execPath, [MODULE, 'archive-gc', '--dry-run', '--json'], { encoding: 'utf8', env: { ...process.env, ...fx.env } });
    assert.strictEqual(JSON.parse(r.stdout).pruned, 0);
    fs.rmSync(fx.work, { recursive: true, force: true });
  });
});
