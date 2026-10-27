'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const cp = require('child_process');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'maintenance.js');
const m = require(MODULE);

function fresh() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-mnt-'));
  const home = path.join(work, 'home');
  const aicm = path.join(home, '.ai-cli-auto-manager');
  fs.mkdirSync(home);
  const env = {
    HOME: home,
    USERPROFILE: home,
    AICM_HOME: aicm,
    TMPDIR: os.tmpdir(),
    TEMP: os.tmpdir(),
    TMP: os.tmpdir(),
  };
  return { work, home, aicm, env };
}

function withEnv(env, fn) {
  const keys = ['HOME', 'USERPROFILE', 'AICM_HOME', 'TMPDIR', 'TEMP', 'TMP', 'AICM_LOCK_STALE_MS'];
  const prev = {};
  for (const k of keys) prev[k] = process.env[k];
  for (const k of keys) {
    if (env[k] === undefined) delete process.env[k];
    else process.env[k] = env[k];
  }
  try { return fn(); } finally {
    for (const k of keys) {
      if (prev[k] === undefined) delete process.env[k];
      else process.env[k] = prev[k];
    }
  }
}

function writeFile(p, text) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text);
}

function runCli(args, env, input) {
  return spawnSync(process.execPath, [MODULE, ...args], {
    encoding: 'utf8',
    input,
    env: { ...process.env, ...env },
  });
}

test('maintenance', { concurrency: false }, async (t) => {
  await t.test('round trip archive and restore', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const source = path.join(fx.home, 'proj', 'session.jsonl');
      writeFile(source, 'transcript');
      const dest = path.join(fx.aicm, 'archive', 'claude-transcripts', '20261024', 'session.jsonl');
      const putRes = m.archivePut({ rule: 'claude-transcripts', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(putRes.ok, true, putRes.error);
      assert.strictEqual(putRes.status, 'archived');
      assert.strictEqual(fs.existsSync(source), false);
      assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'transcript');
      const manifest = JSON.parse(fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${putRes.id}.json`), 'utf8'));
      assert.strictEqual(manifest.status, 'archived');
      assert.strictEqual(manifest.original, source);
      assert.strictEqual(manifest.stored, 'claude-transcripts/20261024/session.jsonl');
      assert.strictEqual(manifest.size, Buffer.byteLength('transcript'));
      const back = m.restore(putRes.id);
      assert.strictEqual(back.ok, true, back.error);
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'transcript');
      assert.strictEqual(fs.existsSync(dest), false);
      const after = JSON.parse(fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${putRes.id}.json`), 'utf8'));
      assert.strictEqual(after.status, 'restored');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  function trySymlink(target, link) {
    try { fs.symlinkSync(target, link); return true; } catch (e) {
      if (process.platform === 'win32' && (e.code === 'EPERM' || e.code === 'EINVAL' || e.code === 'ENOTSUP')) return false;
      throw e;
    }
  }

  await t.test('refuses source symlink, ancestor symlink, dest symlink, and linked AICM_HOME', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const real = path.join(fx.home, 'real');
      writeFile(path.join(real, 'a.txt'), 'keep');
      const link = path.join(fx.home, 'link');
      if (!trySymlink(real, link)) return;
      const via = m.archivePut({
        rule: 'r', root: link, source: path.join(link, 'a.txt'),
        dest: path.join(fx.aicm, 'archive', 'r', 'a.txt'),
      });
      assert.strictEqual(via.ok, false);
      assert.strictEqual(fs.readFileSync(path.join(real, 'a.txt'), 'utf8'), 'keep');

      const src = path.join(fx.home, 'proj', 'b.txt');
      writeFile(src, 'file');
      if (!trySymlink(src, path.join(fx.home, 'proj', 'b-link.txt'))) return;
      const linkedFile = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: path.join(fx.home, 'proj', 'b-link.txt'),
        dest: path.join(fx.aicm, 'archive', 'r', 'b.txt'),
      });
      assert.strictEqual(linkedFile.ok, false);
      assert.strictEqual(fs.readFileSync(src, 'utf8'), 'file');

      const elsewhere = path.join(fx.work, 'elsewhere');
      fs.mkdirSync(path.join(fx.aicm, 'archive', 'r'), { recursive: true });
      if (!trySymlink(elsewhere, path.join(fx.aicm, 'archive', 'r', 'day'))) return;
      const destLink = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: src,
        dest: path.join(fx.aicm, 'archive', 'r', 'day', 'b.txt'),
      });
      assert.strictEqual(destLink.ok, false);
      assert.strictEqual(fs.existsSync(path.join(elsewhere, 'b.txt')), false);
      assert.strictEqual(fs.readFileSync(src, 'utf8'), 'file');

      const outside = path.join(fx.work, 'outside-aicm');
      fs.mkdirSync(outside);
      const linkedHome = path.join(fx.work, 'linked-aicm');
      if (!trySymlink(outside, linkedHome)) return;
      const saved = process.env.AICM_HOME;
      process.env.AICM_HOME = linkedHome;
      const homeLink = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: src,
        dest: path.join(linkedHome, 'archive', 'r', 'b.txt'),
      });
      process.env.AICM_HOME = saved;
      assert.strictEqual(homeLink.ok, false);
      assert.strictEqual(fs.readdirSync(outside).length, 0);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('state symlink blocks archive and history writes', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const outside = path.join(fx.work, 'outside-state');
      fs.mkdirSync(outside);
      fs.mkdirSync(fx.aicm);
      if (!trySymlink(outside, path.join(fx.aicm, 'state'))) return;
      const source = path.join(fx.home, 'proj', 'c.txt');
      writeFile(source, 'safe');
      const putRes = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source,
        dest: path.join(fx.aicm, 'archive', 'r', 'c.txt'),
      });
      assert.strictEqual(putRes.ok, false);
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'safe');
      assert.deepStrictEqual(fs.readdirSync(outside), []);
      const hist = m.historyAdd('clean', { finishedAt: '2020-01-01T00:00:00Z', summary: { files: 1 }, results: [] });
      assert.strictEqual(hist.ok, false);
      assert.deepStrictEqual(fs.readdirSync(outside), []);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('does not overwrite archive dest or restore target', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const source = path.join(fx.home, 'proj', 'd.txt');
      writeFile(source, 'new');
      const dest = path.join(fx.aicm, 'archive', 'r', 'd.txt');
      writeFile(dest, 'keep');
      const putRes = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(putRes.status, 'conflict');
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'new');
      assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'keep');

      fs.unlinkSync(dest);
      const ok = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(ok.ok, true, ok.error);
      writeFile(source, 'busy');
      const back = m.restore(ok.id);
      assert.strictEqual(back.status, 'conflict');
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'busy');
      assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'new');
      const disk = JSON.parse(fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${ok.id}.json`), 'utf8'));
      assert.strictEqual(disk.status, 'archived');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('manifest failure leaves the source in place', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      fs.mkdirSync(path.join(fx.aicm, 'state'), { recursive: true });
      fs.writeFileSync(path.join(fx.aicm, 'state', 'archive-index'), 'not-a-dir');
      const source = path.join(fx.home, 'proj', 'e.txt');
      writeFile(source, 'original');
      const dest = path.join(fx.aicm, 'archive', 'r', 'e.txt');
      const putRes = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(putRes.ok, false);
      assert.strictEqual(putRes.recoverable, true);
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'original');
      assert.strictEqual(fs.existsSync(dest), false);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('copy fallback when hard link is refused', () => {
    const fx = fresh();
    const orig = fs.linkSync;
    fs.linkSync = () => { const e = new Error('exdev'); e.code = 'EXDEV'; throw e; };
    try {
      withEnv(fx.env, () => {
        const source = path.join(fx.home, 'proj', 'f.txt');
        writeFile(source, 'copied');
        const dest = path.join(fx.aicm, 'archive', 'r', 'f.txt');
        const putRes = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
        assert.strictEqual(putRes.ok, true, putRes.error);
        assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'copied');
        assert.strictEqual(fs.existsSync(source), false);
      });
    } finally { fs.linkSync = orig; }
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('traversal, tampered manifest, protected, sqlite, codex', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      assert.strictEqual(m.pathAllowed(fx.home).ok, false);
      const outsideRoot = path.join(path.parse(fx.home).root, 'aicm-not-home');
      assert.strictEqual(m.pathAllowed(outsideRoot).ok, false);
      assert.strictEqual(m.isProtectedPath(path.join(fx.home, 'proj', 'memory', 'fact.md')), true);
      assert.strictEqual(m.isSqliteFamily('logs_2.sqlite-wal'), true);
      assert.strictEqual(m.isCodexNative({ rule: 'codex-images', original: path.join(fx.home, '.codex', 'generated_images', 'a.png') }), false);
      assert.strictEqual(m.isCodexNative({ rule: 'codex', original: path.join(fx.home, 'x') }), true);
      assert.strictEqual(m.validateStored('rule/../../etc/passwd'), false);
      assert.strictEqual(m.validateStored('/tmp/a'), false);
      assert.strictEqual(m.validateStored('rule\\a'), false);
      assert.strictEqual(m.validateStored('C:/rule/a'), false);
      assert.strictEqual(m.tempLooksUsable('/opt/data', '/Users/me'), false);
      assert.strictEqual(m.tempLooksUsable('/var/folders/ab/T', '/Users/me'), true);
      assert.strictEqual(m.tempLooksUsable('/tmp', '/tmp/home'), false);
      const sibling = path.join(fx.work, 'sibling', 'note.txt');
      writeFile(sibling, 'x');
      const underHomeTmp = path.join(fx.home, 'tmp', 'ok.txt');
      writeFile(underHomeTmp, 'ok');
      withEnv({ ...fx.env, TMPDIR: fx.work, TEMP: fx.work, TMP: fx.work }, () => {
        assert.strictEqual(m.tempLooksUsable(fx.work, fx.home), false);
        assert.strictEqual(m.pathAllowed(sibling).ok, false);
        assert.strictEqual(m.pathAllowed(underHomeTmp).ok, true);
      });

      const envFile = path.join(fx.home, 'proj', '.env');
      writeFile(envFile, 'SECRET=1');
      assert.strictEqual(m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: envFile,
        dest: path.join(fx.aicm, 'archive', 'r', '.env'),
      }).ok, false);
      assert.strictEqual(fs.readFileSync(envFile, 'utf8'), 'SECRET=1');

      const mem = path.join(fx.home, 'proj', 'memory', 'fact.md');
      writeFile(mem, 'mem');
      assert.strictEqual(m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: mem,
        dest: path.join(fx.aicm, 'archive', 'r', 'fact.md'),
      }).ok, false);

      const db = path.join(fx.home, 'proj', 'state_5.sqlite');
      writeFile(db, 'db');
      assert.strictEqual(m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: db,
        dest: path.join(fx.aicm, 'archive', 'r', 'state_5.sqlite'),
      }).ok, false);
      const wal = path.join(fx.home, 'proj', 'logs_2.sqlite-wal');
      writeFile(wal, 'wal');
      assert.strictEqual(m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: wal,
        dest: path.join(fx.aicm, 'archive', 'r', 'logs_2.sqlite-wal'),
      }).ok, false);

      const rollout = path.join(fx.home, '.codex', 'sessions', 'rollout-abc');
      writeFile(rollout, 'session');
      assert.strictEqual(m.archivePut({
        rule: 'r', root: path.join(fx.home, '.codex'), source: rollout,
        dest: path.join(fx.aicm, 'archive', 'r', 'rollout-abc'),
      }).ok, false);

      const source = path.join(fx.home, 'proj', 'ok.txt');
      writeFile(source, 'body');
      const ok = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source,
        dest: path.join(fx.aicm, 'archive', 'r', 'ok.txt'),
      });
      assert.strictEqual(ok.ok, true, ok.error);
      const man = path.join(fx.aicm, 'state', 'archive-index', `${ok.id}.json`);
      const rec = JSON.parse(fs.readFileSync(man, 'utf8'));
      rec.stored = 'r/../../secret.txt';
      rec.original = path.join(fx.work, 'victim.txt');
      rec.target = path.join(fx.work, 'other.txt');
      fs.writeFileSync(man, JSON.stringify(rec));
      writeFile(path.join(fx.work, 'victim.txt'), 'KEEP');
      const bad = m.restore(ok.id);
      assert.strictEqual(bad.ok, false);
      assert.strictEqual(fs.readFileSync(path.join(fx.work, 'victim.txt'), 'utf8'), 'KEEP');
      assert.strictEqual(fs.existsSync(path.join(fx.work, 'other.txt')), false);

      rec.stored = 'r/ok.txt';
      rec.original = path.join(fx.home, 'memory', 'note.md');
      rec.rule = 'r';
      fs.writeFileSync(man, JSON.stringify(rec));
      const prot = m.restore(ok.id);
      assert.strictEqual(prot.ok, false);
      assert.strictEqual(fs.existsSync(path.join(fx.home, 'memory', 'note.md')), false);

      rec.original = source;
      rec.rule = 'codex';
      rec.stored = 'codex/ok.txt';
      fs.writeFileSync(man, JSON.stringify(rec));
      assert.strictEqual(m.restore(ok.id).ok, false);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('expired archive is reported and not rewritten; dry-run writes nothing', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const source = path.join(fx.home, 'proj', 'g.txt');
      writeFile(source, 'gone-later');
      const dest = path.join(fx.aicm, 'archive', 'r', 'g.txt');
      const ok = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(ok.ok, true, ok.error);
      const man = path.join(fx.aicm, 'state', 'archive-index', `${ok.id}.json`);
      const before = fs.readFileSync(man);
      fs.unlinkSync(dest);
      const listed = m.archiveList();
      assert.strictEqual(listed.ok, true);
      const item = listed.items.find((i) => i.id === ok.id);
      assert.strictEqual(item.status, 'expired');
      assert.strictEqual(fs.readFileSync(man).equals(before), true);
      const again = m.restore(ok.id);
      assert.strictEqual(again.status, 'expired');
      assert.strictEqual(fs.readFileSync(man).equals(before), true);
      assert.strictEqual(fs.existsSync(source), false);

      writeFile(source, 'back');
      const ok2 = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(ok2.ok, true, ok2.error);
      const man2 = fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${ok2.id}.json`));
      const snap = fs.readFileSync(dest);
      const dry = m.restore(ok2.id, { dryRun: true });
      assert.strictEqual(dry.status, 'would-restore');
      assert.strictEqual(fs.existsSync(source), false);
      assert.strictEqual(fs.readFileSync(dest).equals(snap), true);
      assert.strictEqual(fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${ok2.id}.json`)).equals(man2), true);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('legacy archive, list is read-only, manifest symlink is not followed', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const empty = m.archiveList();
      assert.strictEqual(empty.ok, true);
      assert.strictEqual(fs.existsSync(fx.aicm), false);
      writeFile(path.join(fx.aicm, 'archive', 'r', '20200101', 'old.jsonl'), 'legacy');
      const secret = path.join(fx.work, 'secret.json');
      writeFile(secret, 'SECRET-BLOB');
      fs.mkdirSync(path.join(fx.aicm, 'state', 'archive-index'), { recursive: true });
      if (!trySymlink(secret, path.join(fx.aicm, 'state', 'archive-index', 'linked.json'))) return;
      const outsideDir = path.join(fx.work, 'linked-archive');
      writeFile(path.join(outsideDir, 'hidden.txt'), 'SECRET-BLOB');
      if (!trySymlink(outsideDir, path.join(fx.aicm, 'archive', 'r', 'linked-dir'))) return;
      const listed = m.archiveList();
      assert.strictEqual(JSON.stringify(listed).includes('SECRET-BLOB'), false);
      const legacy = listed.items.find((i) => i.status === 'legacy');
      assert.strictEqual(legacy.stored, 'r/20200101/old.jsonl');
      assert.strictEqual(legacy.note, 'manual restore');
      assert.strictEqual(legacy.original, undefined);
      assert.ok(listed.problems.some((p) => p.error === 'linked manifest'));
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('missing source is recoverable and outside temp root is refused', () => {
    const fx = fresh();
    withEnv({ ...fx.env, TMPDIR: path.join(fx.work, 'no-such-temp'), TEMP: path.join(fx.work, 'no-such-temp'), TMP: path.join(fx.work, 'no-such-temp') }, () => {
      fs.mkdirSync(path.join(fx.home, 'proj'));
      const missing = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: path.join(fx.home, 'proj', 'missing.txt'),
        dest: path.join(fx.aicm, 'archive', 'r', 'missing.txt'),
      });
      assert.strictEqual(missing.status, 'missing');
      assert.strictEqual(missing.recoverable, true);
      assert.strictEqual(fs.existsSync(fx.aicm), false);
      const outside = path.join(fx.work, 'outside.txt');
      writeFile(outside, 'no');
      const refused = m.archivePut({
        rule: 'r', root: fx.work, source: outside,
        dest: path.join(fx.aicm, 'archive', 'r', 'outside.txt'),
      });
      assert.strictEqual(refused.ok, false);
      assert.strictEqual(fs.readFileSync(outside, 'utf8'), 'no');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('file under a usable temp root outside HOME can be archived', () => {
    const fx = fresh();
    const tempRoot = path.join(fx.work, 'tmp');
    fs.mkdirSync(tempRoot);
    withEnv({ ...fx.env, TMPDIR: tempRoot, TEMP: tempRoot, TMP: tempRoot }, () => {
      const source = path.join(tempRoot, 'sess', 't.txt');
      writeFile(source, 'temp');
      const putRes = m.archivePut({
        rule: 'os-temp', root: path.join(tempRoot, 'sess'), source,
        dest: path.join(fx.aicm, 'archive', 'os-temp', 't.txt'),
      });
      assert.strictEqual(putRes.ok, true, putRes.error);
      assert.strictEqual(fs.readFileSync(path.join(fx.aicm, 'archive', 'os-temp', 't.txt'), 'utf8'), 'temp');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('history bounds, dry-run, malformed, and no mutation on read', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const dry = m.historyAdd('clean', { dryRun: true, conversation: 'SECRET-BLOB', summary: { files: 1 } });
      assert.strictEqual(dry.skipped, true);
      assert.strictEqual(fs.existsSync(path.join(fx.aicm, 'state', 'history')), false);
      const added = m.historyAdd('clean', {
        finishedAt: '2020-01-02T00:00:00Z',
        summary: { files: 1, bytes: 4 },
        results: [{ path: path.join(fx.home, 'proj', 'a.txt'), action: 'archived', bytes: 4, rule: 'claude-transcripts', note: 'SECRET-BLOB' }],
      });
      assert.strictEqual(added.ok, true, added.error);
      const stored = fs.readFileSync(path.join(fx.aicm, 'state', 'history', `${added.id}.json`), 'utf8');
      assert.strictEqual(stored.includes('SECRET-BLOB'), false);
      fs.writeFileSync(path.join(fx.aicm, 'state', 'history', 'bad.json'), '{');
      const planted = {
        id: 'planted1', kind: 'update', finishedAt: '2020-01-03T00:00:00Z', summary: { files: 0 }, results: [],
        conversation: 'SECRET-BLOB',
      };
      fs.writeFileSync(path.join(fx.aicm, 'state', 'history', 'planted1.json'), JSON.stringify(planted));
      const before = fs.readFileSync(path.join(fx.aicm, 'state', 'history', 'bad.json'));
      const listed = m.historyList({ limit: 100 });
      assert.strictEqual(listed.ok, true);
      assert.strictEqual(JSON.stringify(listed).includes('SECRET-BLOB'), false);
      assert.ok(listed.problems.some((p) => p.file === 'bad.json'));
      assert.strictEqual(fs.readFileSync(path.join(fx.aicm, 'state', 'history', 'bad.json')).equals(before), true);
      assert.ok(listed.items.some((i) => i.id === 'planted1'));
      for (let i = 0; i < 101; i++) {
        const res = m.historyAdd('restore', { finishedAt: `2021-01-01T00:00:${String(i % 60).padStart(2, '0')}Z`, summary: { restored: i }, results: [] });
        assert.strictEqual(res.ok, true, res.error);
      }
      const all = fs.readdirSync(path.join(fx.aicm, 'state', 'history'));
      assert.ok(all.includes('bad.json'));
      const valid = all.filter((n) => n !== 'bad.json');
      assert.ok(valid.length <= 100, `expected at most 100 valid records, got ${valid.length}`);
      const readAgain = m.historyList({ limit: 1 });
      assert.strictEqual(readAgain.items.length, 1);
      assert.ok(fs.existsSync(path.join(fx.aicm, 'state', 'history', 'bad.json')));
      assert.strictEqual(m.historyList({ limit: 0 }).status, 'usage');
      assert.strictEqual(m.historyList({ limit: 101 }).status, 'usage');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('held lock does not move the source; dead pid lock is reclaimed', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      fs.mkdirSync(path.join(fx.aicm, 'state'), { recursive: true });
      const lock = m.acquireLock(fx.aicm);
      const source = path.join(fx.home, 'proj', 'h.txt');
      writeFile(source, 'locked');
      const blocked = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source,
        dest: path.join(fx.aicm, 'archive', 'r', 'h.txt'),
      });
      assert.strictEqual(blocked.status, 'locked');
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'locked');
      lock.release();
      let dead = 0;
      for (let pid = 100000; pid < 130000; pid++) {
        try { process.kill(pid, 0); } catch (e) { if (e.code === 'ESRCH') { dead = pid; break; } }
      }
      assert.ok(dead > 0);
      const dir = path.join(fx.aicm, 'state', m.LOCK_NAME);
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, 'owner.json'), JSON.stringify({ pid: dead, createdAt: '2020-01-01T00:00:00Z' }));
      const putRes = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source,
        dest: path.join(fx.aicm, 'archive', 'r', 'h.txt'),
      });
      assert.strictEqual(putRes.ok, true, putRes.error);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('CLI json outcomes', () => {
    const fx = fresh();
    const source = path.join(fx.home, 'proj', 'i.txt');
    writeFile(source, 'cli');
    const dest = path.join(fx.aicm, 'archive', 'r', 'day', 'i.txt');
    const putRes = runCli(['archive-put', '--rule', 'r', '--root', path.join(fx.home, 'proj'), '--source', source, '--dest', dest, '--json'], fx.env);
    assert.strictEqual(putRes.status, 0, putRes.stderr);
    const body = JSON.parse(putRes.stdout);
    assert.strictEqual(body.status, 'archived');
    const list = runCli(['archive-list', '--json'], fx.env);
    assert.strictEqual(list.status, 0);
    assert.ok(JSON.parse(list.stdout).items.some((i) => i.id === body.id));
    const dry = runCli(['restore', body.id, '--dry-run', '--json'], fx.env);
    assert.strictEqual(dry.status, 0);
    assert.strictEqual(JSON.parse(dry.stdout).status, 'would-restore');
    assert.strictEqual(fs.existsSync(source), false);
    const hist = runCli(['history-add', '--kind', 'clean', '--file', '-'], fx.env, JSON.stringify({
      finishedAt: '2020-01-01T00:00:00Z', summary: { files: 1 }, results: [{ path: source, action: 'archived' }],
    }));
    assert.strictEqual(hist.status, 0, hist.stderr);
    const shown = runCli(['history', '--json', '--limit', '1'], fx.env);
    assert.strictEqual(shown.status, 0);
    assert.strictEqual(JSON.parse(shown.stdout).items.length, 1);
    const bad = runCli(['history', '--limit', '0'], fx.env);
    assert.strictEqual(bad.status, 2);
    const usage = runCli(['nope'], fx.env);
    assert.strictEqual(usage.status, 2);
  });

  await t.test('fresh lock without owner is kept; an aged one is reclaimed; a live pid is not', () => {
    const fx = fresh();
    withEnv({ ...fx.env, AICM_LOCK_STALE_MS: '1000' }, () => {
      fs.mkdirSync(path.join(fx.aicm, 'state', m.LOCK_NAME), { recursive: true });
      const source = path.join(fx.home, 'proj', 'fresh.txt');
      writeFile(source, 'fresh');
      const dest = path.join(fx.aicm, 'archive', 'r', 'fresh.txt');
      const blocked = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(blocked.status, 'locked');
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'fresh');
      const old = new Date(Date.now() - 10000);
      fs.utimesSync(path.join(fx.aicm, 'state', m.LOCK_NAME), old, old);
      const putRes = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(putRes.ok, true, putRes.error);

      const again = path.join(fx.home, 'proj', 'live.txt');
      writeFile(again, 'live');
      const lock = m.acquireLock(fx.aicm);
      fs.utimesSync(lock.dir, old, old);
      const held = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: again,
        dest: path.join(fx.aicm, 'archive', 'r', 'live.txt'),
      });
      assert.strictEqual(held.status, 'locked');
      assert.strictEqual(fs.readFileSync(again, 'utf8'), 'live');
      lock.release();
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('refuses to replace a manifest symlink and removes its temp file', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const secret = path.join(fx.work, 'secret-meta.txt');
      writeFile(secret, 'SECRET-META');
      const dir = path.join(fx.aicm, 'state', 'history');
      fs.mkdirSync(dir, { recursive: true });
      const stamp = 1700000000000;
      const origNow = Date.now;
      const origBytes = crypto.randomBytes;
      Date.now = () => stamp;
      crypto.randomBytes = (n) => Buffer.alloc(n, 7);
      const id = 'h' + stamp.toString(16) + Buffer.alloc(8, 7).toString('hex');
      const link = path.join(dir, `${id}.json`);
      let linked = true;
      try { fs.symlinkSync(secret, link); } catch (e) {
        linked = false;
        if (!(process.platform === 'win32' && (e.code === 'EPERM' || e.code === 'EINVAL'))) throw e;
      }
      try {
        if (!linked) return;
        const added = m.historyAdd('clean', { finishedAt: '2020-01-01T00:00:00Z', summary: { files: 1 }, results: [] });
        assert.strictEqual(added.ok, false);
        assert.strictEqual(fs.readFileSync(secret, 'utf8'), 'SECRET-META');
        assert.ok(fs.lstatSync(link).isSymbolicLink());
        const temps = fs.readdirSync(dir).filter((name) => name.includes('.tmp'));
        assert.deepStrictEqual(temps, []);
      } finally {
        Date.now = origNow;
        crypto.randomBytes = origBytes;
      }
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('copy fallback keeps a replacement and the only original copy', () => {
    const fx = fresh();
    const origLink = fs.linkSync;
    const origOpen = fs.openSync;
    fs.linkSync = () => { const e = new Error('exdev'); e.code = 'EXDEV'; throw e; };
    let armed = true;
    fs.openSync = function (p, flags, mode) {
      const fd = origOpen.call(fs, p, flags, mode);
      if (armed && p.endsWith(`${path.sep}swap.txt`) && (flags & fs.constants.O_WRONLY) === 0) {
        armed = false;
        fs.unlinkSync(p);
        fs.writeFileSync(p, 'REPLACEMENT');
      }
      return fd;
    };
    try {
      withEnv(fx.env, () => {
        const source = path.join(fx.home, 'proj', 'swap.txt');
        writeFile(source, 'original-bytes');
        const dest = path.join(fx.aicm, 'archive', 'r', 'swap.txt');
        const putRes = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
        assert.strictEqual(putRes.ok, false);
        assert.strictEqual(fs.readFileSync(source, 'utf8'), 'REPLACEMENT');
        assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'original-bytes');
      });
    } finally {
      fs.linkSync = origLink;
      fs.openSync = origOpen;
    }
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('pending manifest can be restored; manifest failure does not delete the original', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const source = path.join(fx.home, 'proj', 'pend.txt');
      writeFile(source, 'pending-body');
      const dest = path.join(fx.aicm, 'archive', 'r', 'pend.txt');
      const ok = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(ok.ok, true, ok.error);
      const man = path.join(fx.aicm, 'state', 'archive-index', `${ok.id}.json`);
      const rec = JSON.parse(fs.readFileSync(man, 'utf8'));
      rec.status = 'pending';
      fs.writeFileSync(man, JSON.stringify(rec));
      const listed = m.archiveList();
      const item = listed.items.find((row) => row.id === ok.id);
      assert.strictEqual(item.status, 'pending');
      assert.strictEqual(item.recoverable, true);
      const back = m.restore(ok.id);
      assert.strictEqual(back.ok, true, back.error);
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'pending-body');

      writeFile(source, 'again');
      const ok2 = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
      assert.strictEqual(ok2.ok, true, ok2.error);
      const man2 = path.join(fx.aicm, 'state', 'archive-index', `${ok2.id}.json`);
      const origRename = fs.renameSync;
      fs.renameSync = (from, to) => {
        if (String(to).endsWith(`${ok2.id}.json`)) throw Object.assign(new Error('disk full'), { code: 'ENOSPC' });
        return origRename(from, to);
      };
      try {
        const failed = m.restore(ok2.id);
        assert.strictEqual(failed.ok, false);
        assert.strictEqual(fs.readFileSync(source, 'utf8'), 'again');
      } finally { fs.renameSync = origRename; }
      const second = m.restore(ok2.id);
      assert.strictEqual(second.ok, false);
      assert.strictEqual(second.status, 'conflict');
      assert.strictEqual(fs.readFileSync(source, 'utf8'), 'again');
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('history keeps updater and clean fields and drops raw blobs', () => {
    const fx = fresh();
    withEnv(fx.env, () => {
      const tool = path.join(fx.home, 'bin', 'claude');
      const update = m.historyAdd('update', {
        ok: true,
        finishedAt: '2020-02-02T00:00:00Z',
        categories: ['sessions'],
        conversation: 'SECRET-CHAT',
        output: 'raw log',
        env: { TOKEN: 'SECRET-CHAT' },
        summary: { files: 1 },
        results: [{
          id: 'claude',
          command: 'claude update',
          before: { path: tool, version: '1.0.0', exitCode: -1073741819 },
          after: { path: tool, version: '1.1.0', exitCode: 3221225477 },
          status: 'verifyFailed',
          reason: 'version mismatch',
        }, { id: 'codex', status: 'updateFailed' }],
      });
      assert.strictEqual(update.ok, true, update.error);
      const clean = m.historyAdd('clean', {
        ok: false,
        finishedAt: '2020-02-03T00:00:00Z',
        categories: ['sessions', 'nope'],
        summary: { plannedBytes: 10, freedBytes: 4, archivedBytes: 6, files: 2 },
        rules: [{
          id: 'claude-transcripts', category: 'sessions', status: 'would remove',
          removed: 3, removedBytes: 4, candidates: 5, candidateBytes: 9, purged: 1, purgedBytes: 2, inUse: 0,
        }],
        results: [{ id: 'claude-transcripts', status: 'archived', path: path.join(fx.home, 'proj', 'a.jsonl') }],
        stdout: 'SECRET-CHAT',
      });
      assert.strictEqual(clean.ok, true, clean.error);
      const listed = m.historyList({ limit: 10 });
      assert.strictEqual(JSON.stringify(listed).includes('SECRET-CHAT'), false);
      const up = listed.items.find((row) => row.kind === 'update');
      assert.strictEqual(up.ok, true);
      assert.deepStrictEqual(up.categories, ['sessions']);
      assert.strictEqual(up.results[0].status, 'verifyFailed');
      assert.strictEqual(up.results[0].before.version, '1.0.0');
      assert.strictEqual(up.results[0].before.exitCode, -1073741819);
      assert.strictEqual(up.results[0].after.exitCode, 3221225477);
      assert.strictEqual(up.results[0].command, 'claude update');
      assert.strictEqual(up.results[1].id, 'codex');
      assert.strictEqual(up.results[1].status, 'updateFailed');
      const cl = listed.items.find((row) => row.kind === 'clean');
      assert.strictEqual(cl.ok, false);
      assert.strictEqual(cl.summary.plannedBytes, 10);
      assert.strictEqual(cl.summary.freedBytes, 4);
      assert.strictEqual(cl.summary.archivedBytes, 6);
      assert.deepStrictEqual(cl.categories, ['sessions']);
      assert.strictEqual(cl.rules[0].id, 'claude-transcripts');
      assert.strictEqual(cl.rules[0].status, 'would remove');
      assert.strictEqual(cl.rules[0].counts.removed, 3);
      assert.strictEqual(cl.rules[0].counts.removedBytes, 4);
      assert.strictEqual(cl.rules[0].counts.candidates, 5);
      assert.strictEqual(cl.rules[0].counts.inUse, 0);
      const raw = fs.readFileSync(path.join(fx.aicm, 'state', 'history', `${update.id}.json`), 'utf8');
      assert.strictEqual(raw.includes('SECRET-CHAT'), false);
      assert.strictEqual(raw.includes('conversation'), false);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('run-clean lease lets nested archive-put proceed and rejects a bad command', () => {
    const fx = fresh();
    const win = process.platform === 'win32';
    const script = path.join(__dirname, '..', '..', 'bin', win ? 'clean_ai_leftovers.ps1' : 'clean_ai_leftovers.sh');
    const engine = win ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') : '/bin/bash';
    const childArgs = win ? ['-NoProfile', '-NonInteractive', '-File', script, '--dry-run'] : [script, '--dry-run'];
    const origSpawn = cp.spawnSync;
    withEnv(fx.env, () => {
      const source = path.join(fx.home, 'proj', 'nested.txt');
      writeFile(source, 'nested');
      const dest = path.join(fx.aicm, 'archive', 'r', 'nested.txt');
      cp.spawnSync = (cmd, args, opts) => {
        assert.strictEqual(cmd, engine);
        assert.deepStrictEqual(args, childArgs);
        assert.strictEqual(opts.shell, false);
        assert.strictEqual(opts.stdio, 'inherit');
        process.env.AICM_MAINTENANCE_LEASE = opts.env.AICM_MAINTENANCE_LEASE;
        process.env.AICM_MAINTENANCE_OWNER = opts.env.AICM_MAINTENANCE_OWNER;
        assert.strictEqual(m.leaseValid(), true);
        const nested = m.archivePut({ rule: 'r', root: path.join(fx.home, 'proj'), source, dest });
        assert.strictEqual(nested.ok, true, nested.error);
        return { status: 3 };
      };
      try {
        const ran = m.runClean(engine, childArgs);
        assert.strictEqual(ran.spawned, true);
        assert.strictEqual(ran.exitCode, 3);
        assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'nested');
        assert.strictEqual(m.leaseValid(), false);
      } finally { cp.spawnSync = origSpawn; }

      const injected = win
        ? m.runClean('pwsh.exe', ['-NoProfile', '-NonInteractive', '-Command', script])
        : m.runClean('/bin/bash', ['-c', script]);
      assert.strictEqual(injected.spawned, false);
      assert.strictEqual(injected.ok, false);

      process.env.AICM_MAINTENANCE_LEASE = 'a'.repeat(64);
      process.env.AICM_MAINTENANCE_OWNER = String(process.pid);
      const lock = m.acquireLock(fx.aicm);
      const source2 = path.join(fx.home, 'proj', 'bad-lease.txt');
      writeFile(source2, 'stay');
      const denied = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source: source2,
        dest: path.join(fx.aicm, 'archive', 'r', 'bad-lease.txt'),
      });
      assert.strictEqual(denied.status, 'locked');
      assert.strictEqual(m.leaseValid(), false);
      assert.strictEqual(fs.readFileSync(source2, 'utf8'), 'stay');
      lock.release();
      delete process.env.AICM_MAINTENANCE_LEASE;
      delete process.env.AICM_MAINTENANCE_OWNER;

      const cliArgs = win
        ? ['run-clean', '--', 'powershell.exe', '-NoProfile', '-NonInteractive', '-File', path.join(fx.work, 'clean_ai_leftovers.ps1'), '-Json']
        : ['run-clean', '--', '/bin/bash', path.join(fx.work, 'nope.sh'), '--json'];
      const cli = runCli(cliArgs, fx.env);
      assert.notStrictEqual(cli.status, 0);
      const doc = JSON.parse(cli.stdout);
      assert.strictEqual(doc.schemaVersion, 1);
      assert.strictEqual(doc.dryRun, false);
      assert.deepStrictEqual(doc.categories, []);
      assert.deepStrictEqual(doc.rules, []);
      assert.strictEqual(doc.summary.plannedBytes, 0);
      assert.strictEqual(doc.summary.freedBytes, 0);
      assert.strictEqual(doc.summary.archivedBytes, 0);
      assert.strictEqual(doc.status, 'error');
      assert.strictEqual(doc.errors.length, 1);
      assert.strictEqual(cli.stdout.trim().split('\n').length, 1);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('history-add accepts a UTF-8 BOM file', () => {
    const fx = fresh();
    const file = path.join(fx.work, 'bom.json');
    fs.writeFileSync(file, `\uFEFF${JSON.stringify({
      finishedAt: '2020-04-04T00:00:00Z', summary: { files: 1 }, results: [{ id: 'claude', status: 'updated' }],
    })}`);
    const cli = runCli(['history-add', '--kind', 'update', '--file', file, '--json'], fx.env);
    assert.strictEqual(cli.status, 0, cli.stderr);
    assert.strictEqual(JSON.parse(cli.stdout).ok, true);
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('USERPROFILE is the home on Windows', () => {
    if (process.platform !== 'win32') return;
    const fx = fresh();
    const env = { ...fx.env };
    delete env.HOME;
    withEnv(env, () => {
      const source = path.join(fx.home, 'proj', 'win.txt');
      writeFile(source, 'win');
      const putRes = m.archivePut({
        rule: 'r', root: path.join(fx.home, 'proj'), source,
        dest: path.join(fx.aicm, 'archive', 'r', 'win.txt'),
      });
      assert.strictEqual(putRes.ok, true, putRes.error);
    });
    fs.rmSync(fx.work, { recursive: true, force: true });
  });

  await t.test('archive-put JSON stdout is ASCII and restores a unicode filename', () => {
    const fx = fresh();
    const name = '\uD55C\uAE00\uD83D\uDE00.txt';
    const source = path.join(fx.home, 'proj', name);
    const body = 'unicode-body-not-in-json';
    writeFile(source, body);
    const dest = path.join(fx.aicm, 'archive', 'r', 'day', name);
    const putRes = runCli(['archive-put', '--rule', 'r', '--root', path.join(fx.home, 'proj'), '--source', source, '--dest', dest, '--json'], fx.env);
    assert.strictEqual(putRes.status, 0, putRes.stderr);
    assert.strictEqual(/[^\x00-\x7f]/.test(putRes.stdout), false);
    const parsed = JSON.parse(putRes.stdout);
    assert.strictEqual(parsed.original, source);
    assert.strictEqual(parsed.stored.endsWith(name), true);
    assert.strictEqual(putRes.stdout.includes(body), false);
    const manifest = fs.readFileSync(path.join(fx.aicm, 'state', 'archive-index', `${parsed.id}.json`));
    assert.ok(manifest.includes(Buffer.from(name, 'utf8')));
    assert.strictEqual(manifest.includes(Buffer.from('\\uD55C')), false);
    const list = runCli(['archive-list', '--json'], fx.env);
    assert.strictEqual(/[^\x00-\x7f]/.test(list.stdout), false);
    assert.strictEqual(JSON.parse(list.stdout).items.find((i) => i.id === parsed.id).original, source);
    const hist = runCli(['history-add', '--kind', 'clean', '--file', '-', '--json'], fx.env, JSON.stringify({
      finishedAt: '2020-01-01T00:00:00Z', summary: { files: 1 }, results: [{ path: source, action: 'archived' }],
    }));
    assert.strictEqual(hist.status, 0, hist.stderr);
    assert.strictEqual(/[^\x00-\x7f]/.test(hist.stdout), false);
    const shown = runCli(['history', '--json', '--limit', '1'], fx.env);
    assert.strictEqual(/[^\x00-\x7f]/.test(shown.stdout), false);
    assert.strictEqual(JSON.parse(shown.stdout).items[0].results[0].path, source);
    assert.strictEqual(shown.stdout.includes(body), false);
    fs.rmSync(fx.work, { recursive: true, force: true });
  });
});
