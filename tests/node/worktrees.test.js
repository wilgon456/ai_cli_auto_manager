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
  commit(repo, '.gitignore', 'node_modules\n.env\n');
  sh(repo, ['push', '-q', '-u', 'origin', 'main']);
  sh(repo, ['remote', 'set-head', 'origin', 'main']);
  // origin looks like GitHub (for the PR proof) but is served from the local bare repository.
  sh(repo, ['config', 'remote.origin.url', 'https://github.com/acme/app.git']);
  sh(repo, ['config', `url.${remote.replace(/\\/g, '/')}.insteadOf`, 'https://github.com/acme/app.git']);
  // a second remote (a fork)
  const fork = path.join(work, 'fork.git');
  sh(work, ['init', '-q', '--bare', '-b', 'main', fork]);
  sh(repo, ['remote', 'add', 'fork', fork]);

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
  // pushed, then deleted on the remote by someone else (a PR closed without merging): only a stale
  // origin/feat/stale ref is left locally, which must not count as "on a remote"
  const stale = wt('wt-stale', 'feat/stale');
  commit(stale, 'f.txt', 'closed PR work');
  sh(stale, ['push', '-q', 'origin', 'feat/stale']);
  sh(work, ['clone', '-q', remote, 'other']);
  sh(path.join(work, 'other'), ['push', '-q', 'origin', '--delete', 'feat/stale']);
  // the same on the second remote: only a fetch of every remote notices the deletion
  const forkStale = wt('wt-forkstale', 'feat/forkstale');
  commit(forkStale, 'g.txt', 'fork work');
  sh(forkStale, ['push', '-q', 'fork', 'feat/forkstale']);
  sh(work, ['clone', '-q', fork, 'other-fork']);
  sh(path.join(work, 'other-fork'), ['push', '-q', 'origin', '--delete', 'feat/forkstale']);
  // merged, but holds an ignored .env that `git worktree remove` would delete
  const env = wt('wt-env', 'feat/env');
  fs.writeFileSync(path.join(env, '.env'), 'TOKEN=secret');
  // its PR was merged into another feature branch (stacked PRs), not into main
  const stacked = wt('wt-stacked', 'feat/stacked');
  const stackedSha = commit(stacked, 'h.txt', 'stacked work');
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

  for (const p of [merged, squash, dirty, unmerged, stale, forkStale, env, stacked]) age(repo, p);

  const gh = path.join(work, 'gh.js');
  // Answers only for origin's repository, like `gh pr list --repo acme/app`.
  fs.writeFileSync(gh, `if (process.argv.join(' ').indexOf('--repo acme/app') < 0) process.exit(1);
process.stdout.write(${JSON.stringify(JSON.stringify([
    { number: 7, headRefName: 'feat/squash', headRefOid: squashSha, baseRefName: 'main' },
    { number: 8, headRefName: 'old-squash', headRefOid: branchSquashSha, baseRefName: 'main' },
    { number: 9, headRefName: 'feat/stacked', headRefOid: stackedSha, baseRefName: 'feat/base' },
  ]))});\n`);
  return { work, home, root, repo, outside, linked, paths: { merged, squash, dirty, unmerged, recent, stale, forkStale, env, stacked }, gh };
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
    assert.match(out, /keep +\S*wt-env \[feat\/env\] ignored files that are not build output: \.env/);
    assert.match(out, /keep +\S*wt-stacked \[feat\/stacked\] commits not merged or pushed/);
    assert.match(out, /keep +\S*wt-forkstale \[feat\/forkstale\] commits not merged or pushed/);
    assert.match(out, /attention: work left behind in \S*wt-dirty: uncommitted changes\r?\n/);
    assert.match(out, /attention: work left behind in \S*wt-env: ignored files/);
    assert.strictEqual(sh(ctx.repo, ['for-each-ref', 'refs/aicm-deleted/']), '', 'report mode writes no backup refs');
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
    assert.ok(fs.existsSync(ctx.paths.stale), 'work only in a stale remote-tracking ref is kept');
    assert.ok(fs.existsSync(path.join(ctx.paths.stale, 'f.txt')), '... with its files');
    assert.ok(fs.existsSync(path.join(ctx.outside, 'precious.txt')), 'link target outside the worktree never touched');
    assert.ok(fs.existsSync(path.join(ctx.paths.env, '.env')), 'ignored .env kept with its worktree');
    assert.ok(fs.existsSync(ctx.paths.stacked), 'PR merged into another branch is no proof');
    assert.ok(fs.existsSync(ctx.paths.forkStale), 'stale ref on a second remote is no proof');
    const backups = sh(ctx.repo, ['for-each-ref', '--format=%(refname)', 'refs/aicm-deleted/']).split(/\r?\n/);
    for (const b of ['feat/merged', 'feat/squash', 'old-merged', 'old-squash']) {
      assert.ok(backups.some((r) => new RegExp(`^refs/aicm-deleted/\\d{4}-\\d{2}-\\d{2}/${b}$`).test(r)), `backup ref for ${b}`);
    }
    const branches = sh(ctx.repo, ['branch', '--format=%(refname:short)']).split(/\r?\n/);
    assert.ok(!branches.includes('feat/merged') && !branches.includes('feat/squash'), 'branches of removed worktrees deleted');
    assert.ok(!branches.includes('old-merged'), 'old merged branch deleted');
    assert.ok(!branches.includes('old-squash'), 'old squash-merged branch deleted (PR head matches)');
    for (const b of ['main', 'old-local', 'feat/dirty', 'feat/unmerged', 'feat/recent', 'feat/stale', 'feat/forkstale', 'feat/env', 'feat/stacked']) assert.ok(branches.includes(b), `${b} kept`);
    assert.doesNotMatch(sh(ctx.repo, ['worktree', 'list', '--porcelain']), /wt-gone/, 'missing worktree pruned');
    assert.match(out, /removed/);
    // Announced once: a second run does not repeat the attention line.
    assert.doesNotMatch(runModule(ctx, []), /attention:/);
  } finally { fs.rmSync(ctx.work, { recursive: true, force: true }); }
});
