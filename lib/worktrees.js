#!/usr/bin/env node
// Worktree and branch hygiene for repositories that AI agents work in (Paseo, Orca, Codex, Claude Code...).
//
//   node worktrees.js [--apply] [--days 14] [--root DIR]... [--json]
//
// Without --apply nothing changes (report only). With --apply:
//   - `git worktree prune` for worktrees whose folder is gone
//   - `git worktree remove` (never --force) for a linked worktree that is clean, untouched for --days,
//     not locked, and whose work is safely upstream: merged into the default branch, or its branch's
//     GitHub PR was merged with exactly this commit (squash merges), or every commit is on a remote
//   - `git branch -d` / `-D` for local branches with the same proof, not checked out anywhere
// A worktree that holds ignored files other than build output (.env, local databases, notes) is kept, since
// `git worktree remove` would delete them. Links inside ignored folders are unlinked first, so removal never
// walks into what they point to. Every removed commit stays reachable under refs/aicm-deleted/<date>/ for
// 90 days. The main worktree, its current branch and the default branch are never touched.
//
// Repositories are found under the roots in ~/.ai-cli-auto-manager/repos.conf (one folder per line),
// or, without that file, under common code folders in the home directory (3 levels deep).
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const common = require('./node-common');

const DEFAULT_ROOTS = ['Desktop', 'dev', 'Dev', 'code', 'src', 'projects', 'repos', 'git', 'work', 'Documents/GitHub', 'Documents/Codex'];
const PROTECTED_BRANCHES = new Set(['main', 'master', 'develop', 'dev', 'trunk', 'release', 'production']);
const SKIP_DIRS = new Set(['node_modules', '.git', '.venv', 'venv', '__pycache__', 'dist', 'build', '.next', 'target', 'AppData', 'Library']);

function run(cmd, args, cwd) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024 });
  return { code: r.status === null ? 1 : r.status, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

// --no-optional-locks: `git status` must not rewrite the index, or every scan would look like recent use.
const git = (cwd, args) => run('git', ['--no-optional-locks', '-C', cwd, ...args]);

function isLink(p) {
  try { return fs.lstatSync(p).isSymbolicLink(); } catch { return false; }
}

function readRoots(home, aicmHome, extra) {
  if (extra.length) return extra;
  const conf = path.join(aicmHome, 'repos.conf');
  if (fs.existsSync(conf)) {
    return fs.readFileSync(conf, 'utf8').split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'))
      .map((l) => (l === '~' ? home : l.startsWith('~/') || l.startsWith('~\\') ? path.join(home, l.slice(2)) : l));
  }
  return DEFAULT_ROOTS.map((r) => path.join(home, r)).filter((p) => fs.existsSync(p));
}

// Main worktrees (a .git folder, not a .git file) up to `depth` levels below each root.
function findRepos(roots, depth = 3) {
  const found = new Set();
  const walk = (dir, level) => {
    if (isLink(dir)) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    if (entries.some((e) => e.name === '.git' && e.isDirectory())) { found.add(path.resolve(dir)); }
    if (level >= depth) return;
    for (const e of entries) {
      if (!e.isDirectory() || SKIP_DIRS.has(e.name) || e.name.startsWith('.')) continue;
      walk(path.join(dir, e.name), level + 1);
    }
  };
  for (const r of roots) walk(r, 0);
  return [...found].sort();
}

function parseWorktrees(porcelain) {
  const list = [];
  let cur = null;
  for (const line of porcelain.split(/\r?\n/)) {
    if (line.startsWith('worktree ')) { cur = { path: line.slice(9), branch: '', head: '', locked: false, prunable: false }; list.push(cur); }
    else if (!cur) continue;
    else if (line.startsWith('HEAD ')) cur.head = line.slice(5);
    else if (line.startsWith('branch ')) cur.branch = line.slice(7).replace(/^refs\/heads\//, '');
    else if (line.startsWith('locked')) cur.locked = true;
    else if (line.startsWith('prunable')) cur.prunable = true;
  }
  return list;
}

function defaultBranch(repo) {
  const r = git(repo, ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']);
  if (r.code === 0 && r.out) return r.out;
  for (const b of ['main', 'master']) if (git(repo, ['rev-parse', '--verify', '--quiet', b]).code === 0) return b;
  return '';
}

// owner/name of the GitHub repository behind `origin`, or '' when origin is not on GitHub.
function githubRepo(repo) {
  // The configured URL, not `remote get-url` (that one applies url.*.insteadOf rewrites).
  const url = git(repo, ['config', '--get', 'remote.origin.url']).out;
  const m = /github\.com[:/]([^/]+)\/([^/]+?)(\.git)?\/?$/i.exec(url || '');
  return m ? `${m[1]}/${m[2]}` : '';
}

// head commit -> merged PR, from one `gh pr list` per repository. Only PRs of origin's own GitHub
// repository that were merged into the default branch count. Empty when gh is unavailable.
function mergedPrHeads(repo, base) {
  const gh = process.env.AICM_GH === '0' ? null : (process.env.AICM_GH || 'gh');
  const slug = githubRepo(repo);
  if (!gh || !slug) return new Map();
  // AICM_GH may point to a .js stand-in (tests); run it with this Node.
  const [cmd, ...pre] = gh.endsWith('.js') ? [process.execPath, gh] : [gh];
  const r = run(cmd, [...pre, 'pr', 'list', '--repo', slug, '--state', 'merged', '--limit', '1000', '--json', 'headRefName,headRefOid,baseRefName,number'], repo);
  if (r.code !== 0) return new Map();
  const baseName = base.replace(/^[^/]+\//, '');
  try {
    // A PR merged into another feature branch (stacked PRs) proves nothing about the default branch.
    return new Map(JSON.parse(r.out).filter((p) => !baseName || p.baseRefName === baseName).map((p) => [p.headRefOid, p]));
  } catch { return new Map(); }
}

// Why it is safe to drop this commit, or '' when it is not.
// Remote-tracking refs can be stale (a branch deleted on a remote stays in <remote>/* until a prune), so
// "every commit is on a remote" only counts right after `fetch --all --prune` succeeded for every remote.
function upstreamProof(repo, sha, branch, base, prs, fetched) {
  if (base && git(repo, ['merge-base', '--is-ancestor', sha, base]).code === 0) return `merged into ${base}`;
  const pr = prs.get(sha);
  if (pr && (!branch || pr.headRefName === branch)) return `PR #${pr.number} merged`;
  if (!fetched) return '';
  const unique = git(repo, ['rev-list', '--count', sha, '--not', '--remotes']);
  if (unique.code === 0 && unique.out === '0') return 'all commits are on a remote';
  return '';
}

function lastActivity(wt) {
  let newest = 0;
  const idx = git(wt, ['rev-parse', '--git-path', 'index']);
  if (idx.code === 0) {
    const p = path.isAbsolute(idx.out) ? idx.out : path.join(wt, idx.out);
    try { newest = Math.max(newest, fs.statSync(p).mtimeMs); } catch { /* no index yet */ }
  }
  const t = git(wt, ['log', '-1', '--format=%ct']);
  if (t.code === 0 && t.out) newest = Math.max(newest, Number(t.out) * 1000);
  try { newest = Math.max(newest, fs.statSync(wt).mtimeMs); } catch { /* gone */ }
  return newest;
}

// Ignored files `git worktree remove` would delete although `git status` calls the worktree clean.
// Build output and dependency folders can be recreated; anything else (.env, local databases, notes)
// keeps the worktree. Returns the ignored paths that are not regenerable.
const REGENERABLE = new Set(['node_modules', '.venv', 'venv', '__pycache__', 'dist', 'build', 'out', '.next', '.nuxt', '.svelte-kit',
  '.turbo', '.cache', '.parcel-cache', 'target', 'coverage', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.gradle', '.tox', 'bin', 'obj']);
function ignoredEntries(wt) {
  const r = git(wt, ['status', '--porcelain', '-z', '--ignored']);
  return r.out.split('\0').filter((l) => l.startsWith('!! ')).map((l) => l.slice(3).replace(/\/$/, ''));
}
function nonRegenerable(ignored) {
  return ignored.filter((p) => !p.split('/').some((seg) => REGENERABLE.has(seg)));
}

// Remove symlinks/junctions inside ignored folders (the links only, never their targets), so that
// `git worktree remove` cannot walk into what they point to. Tracked symlinks are left to git.
function unlinkIgnoredLinks(wt, ignored) {
  let removed = 0;
  const stack = ignored.map((p) => path.join(wt, p));
  while (stack.length) {
    const p = stack.pop();
    if (isLink(p)) {
      try { fs.unlinkSync(p); } catch { fs.rmdirSync(p); }
      removed++;
      continue;
    }
    let entries;
    try { entries = fs.readdirSync(p, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) stack.push(path.join(p, e.name));
  }
  return removed;
}

// A folder another program is working in (Windows: current directory or open files) cannot be renamed.
function inUse(dir) {
  const probe = `${dir}.aicm-check`;
  try { fs.renameSync(dir, probe); } catch { return true; }
  fs.renameSync(probe, dir);
  return false;
}

// Keeps the commit reachable for BACKUP_DAYS after its branch or worktree is removed:
//   git branch <name> refs/aicm-deleted/<date>/<name>
const BACKUP_DAYS = 90;
function backupRef(repo, name, sha, now) {
  const day = new Date(now).toISOString().slice(0, 10);
  const ref = `refs/aicm-deleted/${day}/${(name || `detached-${sha.slice(0, 12)}`).replace(/[^A-Za-z0-9._/-]/g, '_')}`;
  return git(repo, ['update-ref', ref, sha]).code === 0 ? ref : '';
}
function pruneBackupRefs(repo, now) {
  const refs = git(repo, ['for-each-ref', '--format=%(refname)', 'refs/aicm-deleted/']).out.split(/\r?\n/).filter(Boolean);
  for (const ref of refs) {
    const m = /^refs\/aicm-deleted\/(\d{4}-\d{2}-\d{2})\//.exec(ref);
    if (m && now - Date.parse(`${m[1]}T00:00:00Z`) > BACKUP_DAYS * 86400000) git(repo, ['update-ref', '-d', ref]);
  }
}

function checkRepo(repo, opts) {
  const report = { repo, prunable: 0, worktrees: [], branches: [], fetched: false, hasRemote: Boolean(git(repo, ['remote']).out) };
  if (process.env.AICM_WORKTREES_FETCH !== '0' && report.hasRemote) {
    // Every remote, since the "on a remote" proof looks at all of them. Never wait for a password prompt.
    const f = spawnSync('git', ['--no-optional-locks', '-C', repo, 'fetch', '--all', '--prune', '--quiet'], {
      encoding: 'utf8', windowsHide: true, timeout: 180000,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never', GIT_ASKPASS: '', SSH_ASKPASS: '' },
    });
    report.fetched = f.status === 0;
  }
  if (opts.apply) pruneBackupRefs(repo, opts.now);
  const prune = git(repo, ['worktree', 'prune', '--dry-run', '-v']);
  // git prints the dry-run list on stderr.
  report.prunable = `${prune.out}\n${prune.err}`.split(/\r?\n/).filter((l) => /^Removing /.test(l)).length;
  if (opts.apply && report.prunable) git(repo, ['worktree', 'prune']);

  const base = defaultBranch(repo);
  const prs = mergedPrHeads(repo, base);
  const cutoff = opts.now - opts.days * 86400000;
  const all = parseWorktrees(git(repo, ['worktree', 'list', '--porcelain']).out);
  const main = all[0];
  for (const wt of all.slice(1)) {
    if (wt.prunable || !fs.existsSync(wt.path)) continue;
    const item = { path: wt.path, branch: wt.branch, action: 'keep', reason: '' };
    const activity = lastActivity(wt.path);
    const status = git(wt.path, ['status', '--porcelain']);
    const idleDays = Math.max(0, Math.floor((opts.now - activity) / 86400000));
    if (wt.locked) item.reason = 'locked';
    else if (status.code !== 0) item.reason = 'git status failed';
    else if (status.out) {
      item.reason = `uncommitted changes, idle ${idleDays}d`;
      if (idleDays >= opts.abandonDays) item.abandoned = true;
    } else if (activity > cutoff) item.reason = `used ${idleDays}d ago`;
    else {
      const ignored = ignoredEntries(wt.path);
      const keepers = nonRegenerable(ignored);
      const proof = upstreamProof(repo, wt.head, wt.branch, base, prs, report.fetched);
      if (keepers.length) {
        item.reason = `ignored files that are not build output: ${keepers.slice(0, 3).join(', ')}${keepers.length > 3 ? ', ...' : ''}`;
        if (idleDays >= opts.abandonDays) item.abandoned = true;
      } else if (!proof) item.reason = 'commits not merged or pushed';
      else if (opts.apply && inUse(wt.path)) item.reason = 'in use by another program';
      else {
        item.action = opts.apply ? 'removed' : 'would remove';
        item.reason = `${proof}, idle ${idleDays}d`;
        if (opts.apply) {
          item.backup = backupRef(repo, wt.branch, wt.head, opts.now);
          item.links = unlinkIgnoredLinks(wt.path, ignored);
          const r = git(repo, ['worktree', 'remove', wt.path]);
          if (r.code !== 0) {
            item.action = 'keep';
            item.reason = `git worktree remove failed: ${r.err.split('\n')[0]}${fs.existsSync(wt.path) ? '' : ' (folder partly removed)'}`;
          }
        }
      }
    }
    report.worktrees.push(item);
  }

  // Branches: re-read worktrees after removals so a branch freed above can go too.
  const checkedOut = new Set(parseWorktrees(git(repo, ['worktree', 'list', '--porcelain']).out).map((w) => w.branch).filter(Boolean));
  const refs = git(repo, ['for-each-ref', 'refs/heads', '--format=%(refname:short)%09%(objectname)%09%(committerdate:unix)']);
  for (const line of refs.out.split(/\r?\n/).filter(Boolean)) {
    const [name, sha, when] = line.split('\t');
    if (PROTECTED_BRANCHES.has(name) || name === (main && main.branch) || name === base.replace(/^[^/]+\//, '') || checkedOut.has(name)) continue;
    if (Number(when) * 1000 > cutoff) continue;
    const proof = upstreamProof(repo, sha, name, base, prs, report.fetched);
    if (!proof) continue;
    const item = { branch: name, action: opts.apply ? 'deleted' : 'would delete', reason: proof };
    if (opts.apply) {
      item.backup = backupRef(repo, name, sha, opts.now);
      // -d when git itself can see the merge; -D only with proof that this exact commit is upstream.
      const ancestor = base && git(repo, ['merge-base', '--is-ancestor', sha, base]).code === 0;
      const r = git(repo, ['branch', ancestor ? '-d' : '-D', name]);
      if (r.code !== 0) { item.action = 'keep'; item.reason = `git branch failed: ${r.err.split('\n')[0]}`; }
    }
    report.branches.push(item);
  }
  return report;
}

function main(argv) {
  const opts = { apply: false, days: 14, abandonDays: 30, roots: [], json: false, now: Date.now() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--json') opts.json = true;
    else if (a === '--days') opts.days = Number(argv[++i]);
    else if (a === '--root') opts.roots.push(argv[++i]);
    else if (a === '-h' || a === '--help') { console.log('usage: worktrees.js [--apply] [--days 14] [--root DIR]... [--json]'); return 0; }
    else { console.error(`unknown argument: ${a}`); return 2; }
  }
  if (!(opts.days >= 1)) { console.error('--days must be >= 1'); return 2; }
  if (run('git', ['--version']).code !== 0) { console.log('worktrees: git not found, skipped'); return 0; }

  const { home, aicmHome } = common.paths();
  const roots = readRoots(home, aicmHome, opts.roots);
  const repos = findRepos(roots);
  const reports = repos.map((r) => checkRepo(r, opts));

  let wtCount = 0; let wtDone = 0; let brDone = 0; let pruned = 0;
  const attention = [];
  for (const r of reports) {
    pruned += r.prunable;
    const acted = r.worktrees.filter((w) => w.action !== 'keep');
    wtCount += r.worktrees.length; wtDone += acted.length; brDone += r.branches.filter((b) => b.action !== 'keep').length;
    if (!r.worktrees.length && !r.branches.length && !r.prunable) continue;
    if (!opts.json) {
      console.log(`${common.display(r.repo, home)}: ${r.worktrees.length} worktrees, ${r.prunable} with missing folder${opts.apply ? ' (pruned)' : ''}${r.hasRemote && !r.fetched ? ' (remote not reachable: remote-only proofs not used)' : ''}`);
      for (const w of r.worktrees) console.log(`  ${w.action.padEnd(12)} ${common.display(w.path, home)} [${w.branch || 'detached'}] ${w.reason}`);
      for (const b of r.branches) console.log(`  ${b.action.padEnd(12)} branch ${b.branch}: ${b.reason}`);
    }
    // Fixed wording (no day counts), so each worktree is announced once instead of on every run.
    for (const w of r.worktrees) if (w.abandoned) attention.push(`work left behind in ${common.display(w.path, home)}: ${w.reason.replace(/, idle \d+d$/, '')}`);
  }
  const verb = opts.apply ? '' : 'would be ';
  const summary = `${repos.length} repositories, ${wtCount} linked worktrees: ${wtDone} ${verb}removed, ${pruned} ${verb}pruned; ${brDone} merged branches ${verb}deleted`;
  common.writeState(aicmHome, 'worktrees', { finishedAt: new Date(opts.now).toISOString(), apply: opts.apply, summary, attention, repos: reports });
  if (opts.json) console.log(JSON.stringify({ summary, attention, repos: reports }, null, 2));
  else {
    console.log(summary);
    for (const a of common.newSince(aicmHome, 'worktrees-attention', attention)) console.log(`attention: ${a}`);
  }
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = { parseWorktrees, findRepos, upstreamProof, checkRepo, nonRegenerable, githubRepo };
