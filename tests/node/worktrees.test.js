// Tests for lib/worktrees.js against throwaway git repositories (never the real ones) and a fake gh.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'worktrees.js');
const OLD = '2020-01-01T00:00:00Z';
const oldTime = new Date(OLD);

function sh(cwd, args, extraEnv = {}) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8', env: { ...process.env, ...extraEnv } });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

const OLD_ENV = { GIT_AUTHOR_DATE: OLD, GIT_COMMITTER_DATE: OLD };

function commit(cwd, file, msg, old = true) {
  fs.writeFileSync(path.join(cwd, file), msg);
  sh(cwd, ['add', file]);
  sh(cwd, ['commit', '-q', '-m', msg], old ? OLD_ENV : {});
  return sh(cwd, ['rev-parse', 'HEAD']);
}

// Make a worktree look untouched since 2020 (folder and its index).
function age(repo, wt) {
  const name = path.basename(wt);
  const index = path.join(repo, '.git', 'worktrees', name, 'index');
  if (fs.existsSync(index)) fs.utimesSync(index, oldTime, oldTime);
  fs.utimesSync(wt, oldTime, oldTime);
}

function setup() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-wt-'));
  const home = path.join(work, 'home');
  const root = path.join(home, 'code');
  const remote = path.join(work, 'remote.git');
  const repo = path.join(root, 'app');
  const outside = path.join(work, 'outside');
  fs.mkdirSync(root, { recursive: true });
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, 'precious.txt'), 'keep me');
  sh(work, ['init', '-q', '--bare', '-b', 'main', remote]);
  sh(root, ['clone', '-q', remote, 'app']);
  for (const [k, v] of [['user.email', 't@example.com'], ['user.name', 'test'], ['commit.gpgsign', 'false']]) sh(repo, ['config', k, v]);
  commit(repo, 'README.md', 'init');
  commit(repo, '.gitignore', 'node_modules\n');
  sh(repo, ['push', '-q', '-u', 'origin', 'main']);
  sh(repo, ['remote', 'set-head', 'origin', 'main']);

  const wt = (name, branch) => { const p = path.join(work, name); sh(repo, ['worktree', 'add', '-q', '-b', branch, p]); return p; };
  // merged into main (ancestry), old, with a link inside pointing outside the worktree
  const merged = wt('wt-merged', 'feat/merged');
  commit(merged, 'a.txt', 'merged work');
  sh(repo, ['merge', '-q', '--ff-only', 'feat/merged']);
  sh(repo, ['push', '-q', 'origin', 'main']);
  let linked = true;
  // like a node_modules folder linked to a shared copy (ignored by git)
  try { fs.symlinkSync(outside, path.join(merged, 'node_modules'), process.platform === 'win32' ? 'junction' : 'dir'); } catch { linked = false; }
  // squash-merged: not an ancestor of main, but gh says PR #7 merged this exact commit
  const squash = wt('wt-squash', 'feat/squash');
  const squashSha = commit(squash, 'b.txt', 'squash work');
  // uncommitted change, untouched since 2020
  const dirty = wt('wt-dirty', 'feat/dirty');
  fs.writeFileSync(path.join(dirty, 'wip.txt'), 'not committed');
  // committed but never pushed or merged
  const unmerged = wt('wt-unmerged', 'feat/unmerged');
  commit(unmerged, 'c.txt', 'local only');
  // merged but used recently
  const recent = wt('wt-recent', 'feat/recent');
  sh(repo, ['merge', '-q', '--ff-only', 'feat/recent']);
  // folder deleted by hand
  const gone = wt('wt-gone', 'feat/gone');
  fs.rmSync(gone, { recursive: true, force: true });
  // plain branches (no worktree)
  sh(repo, ['branch', 'old-merged', 'main']);
  sh(repo, ['checkout', '-q', '-b', 'old-squash']);
  const branchSquashSha = commit(repo, 'd.txt', 'branch squash');
  sh(repo, ['checkout', '-q', '-b', 'old-local']);
  commit(repo, 'e.txt', 'branch local');
  sh(repo, ['checkout', '-q', 'main']);

  for (const p of [merged, squash, dirty, unmerged]) age(repo, p);

  const gh = path.join(work, 'gh.js');
  fs.writeFileSync(gh, `process.stdout.write(${JSON.stringify(JSON.stringify([
    { number: 7, headRefName: 'feat/squash', headRefOid: squashSha },
    { number: 8, headRefName: 'old-squash', headRefOid: branchSquashSha },
  ]))});\n`);
  return { work, home, root, repo, outside, linked, paths: { merged, squash, dirty, unmerged, recent }, gh };
}

function runModule(ctx, args) {
  const env = { ...process.env, HOME: ctx.home, USERPROFILE: ctx.home, AICM_HOME: path.join(ctx.home, '.aicm'), AICM_GH: ctx.gh };
  const r = spawnSync(process.execPath, [MODULE, '--root', ctx.root, ...args], { encoding: 'utf8', env });
  assert.strictEqual(r.status, 0, r.stderr);
  return r.stdout;
}

test('report mode changes nothing', () => {
  const ctx = setup();
  try {
    const out = runModule(ctx, []);
    assert.match(out, /would remove +\S*wt-merged \[feat\/merged\] merged into origin\/main/);
    assert.match(out, /would remove +\S*wt-squash \[feat\/squash\] PR #7 merged/);
    assert.match(out, /keep +\S*wt-dirty \[feat\/dirty\] uncommitted changes/);
    assert.match(out, /keep +\S*wt-unmerged \[feat\/unmerged\] commits not merged or pushed/);
    assert.match(out, /keep +\S*wt-recent \[feat\/recent\] used 0d ago/);
    assert.match(out, /1 with missing folder/);
    for (const p of Object.values(ctx.paths)) assert.ok(fs.existsSync(p), `${p} must still exist`);
    assert.match(out, /attention: uncommitted work left in \S*wt-dirty/);
  } finally { fs.rmSync(ctx.work, { recursive: true, force: true }); }
});

test('apply removes only what is safely upstream', () => {
  const ctx = setup();
  try {
    const out = runModule(ctx, ['--apply']);
    assert.ok(!fs.existsSync(ctx.paths.merged), 'merged worktree removed');
    assert.ok(!fs.existsSync(ctx.paths.squash), 'squash-merged worktree removed');
    assert.ok(fs.existsSync(ctx.paths.dirty), 'dirty worktree kept');
    assert.ok(fs.existsSync(path.join(ctx.paths.dirty, 'wip.txt')), 'uncommitted file kept');
    assert.ok(fs.existsSync(ctx.paths.unmerged), 'unmerged worktree kept');
    assert.ok(fs.existsSync(ctx.paths.recent), 'recent worktree kept');
    assert.ok(fs.existsSync(path.join(ctx.outside, 'precious.txt')), 'link target outside the worktree never touched');
    const branches = sh(ctx.repo, ['branch', '--format=%(refname:short)']).split(/\r?\n/);
    assert.ok(!branches.includes('feat/merged') && !branches.includes('feat/squash'), 'branches of removed worktrees deleted');
    assert.ok(!branches.includes('old-merged'), 'old merged branch deleted');
    assert.ok(!branches.includes('old-squash'), 'old squash-merged branch deleted (PR head matches)');
    for (const b of ['main', 'old-local', 'feat/dirty', 'feat/unmerged', 'feat/recent']) assert.ok(branches.includes(b), `${b} kept`);
    assert.doesNotMatch(sh(ctx.repo, ['worktree', 'list', '--porcelain']), /wt-gone/, 'missing worktree pruned');
    assert.match(out, /removed/);
    // Announced once: a second run does not repeat the attention line.
    assert.doesNotMatch(runModule(ctx, []), /attention:/);
  } finally { fs.rmSync(ctx.work, { recursive: true, force: true }); }
});
