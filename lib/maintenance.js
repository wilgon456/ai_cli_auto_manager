#!/usr/bin/env node
// Archive index, restore, and bounded run history for AI CLI Auto Manager.
//
// Shell cleanup uses a different lock (temp/ai-cli-auto-manager-clean-<uid>.lockdir).
// Archive date-folder purge must take this same directory lock before deleting:
//   <AICM_HOME>/state/maintenance.lock
// Manifests live in <AICM_HOME>/state/archive-index (not under archive/<rule>/<date>,
// so retention purge does not treat them as archived user files).
// Legacy files already under archive/ are listed only, with note "manual restore".
// archive-list reads the index newest first (manifest ids start with the creation time) and returns a
// page (--limit, default and maximum 10000; --offset). A file under archive/ is called legacy only when
// every manifest was read (at most 100000) and none points at it, and the bounded walk of archive/
// finished; otherwise "legacy.complete" is false and no file is guessed to be legacy. Legacy rows come
// with the first page only.
// archive-gc drops index records that can never be restored again: "restored" records older than 30
// days, and "archived" records whose dated archive folder (archive/<rule>/<yyyymmdd>) the retention
// purge already removed, once a day old. It reads at most 10000 records per run, oldest first, under the
// maintenance lock (or the cleanup's lease). Pending, missing, conflict, malformed and still-restorable
// records, and every file that is not a manifest, are never removed. --dry-run takes no lock and
// changes nothing.
//
//   node maintenance.js archive-put --rule ID --root ROOT --source FILE --dest FILE [--json]
//   node maintenance.js archive-list [--json] [--limit N] [--offset N]
//   node maintenance.js archive-gc [--dry-run] [--json]
//   node maintenance.js restore ID [--dry-run] [--json]
//   node maintenance.js history-add --kind clean|update|restore [--file PATH|-] [--dry-run] [--json]
//   node maintenance.js history [--json] [--limit N]
//   node maintenance.js run-clean -- /bin/bash <checkout>/bin/clean_ai_leftovers.sh ARG...
//   node maintenance.js run-clean -- powershell.exe -NoProfile -NonInteractive -File <checkout>/bin/clean_ai_leftovers.ps1 ARG...
//   (pwsh.exe is accepted in place of powershell.exe)
//
// run-clean holds state/maintenance.lock for the whole child, including purge.
// The interpreter and its arguments are spawned exactly (shell:false, stdio inherit).
// Unix: basename bash, first arg this module's ../bin/clean_ai_leftovers.sh.
// Windows: basename powershell.exe or pwsh.exe, then -NoProfile -NonInteractive -File
// and this module's ../bin/clean_ai_leftovers.ps1. -c and -Command are refused.
// The installed copy uses the same ../bin because the module is installed with it.
// The child receives AICM_MAINTENANCE_LEASE and AICM_MAINTENANCE_OWNER.
// leaseValid() is true only when that pair matches the no-follow owner.json
// of a live owner under a real state directory. archive-put treats a valid
// inherited lease as already holding the lock. restore always takes the lock.
//
// Exit 0 ok (including dry-run skip and recoverable reports that set ok:true only on success).
// Exit 1 refused, conflict, missing, locked, or unsafe. Exit 2 usage.
// archive-list and history do not create directories, locks, or manifest updates.
// Missing source: { ok:false, status:'missing', recoverable:true } and the source is untouched.
// A manifest write that fails before the move leaves the source in place.
// Restore marks status "restored" only after the original path holds the bytes.
// Generic restore refuses Codex-native sessions (rule codex, rollout-*, .codex/sessions,
// archived_sessions, state_N.sqlite). It does not invent paths for legacy archive files.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const common = require('./node-common');

const MAX_MANIFEST_BYTES = 64 * 1024;
const MAX_INPUT = 256 * 1024;
const MAX_ENTRIES = 10000;
const INDEX_SCAN_LIMIT = 100000;
const LEGACY_WALK_LIMIT = 100000;
const GC_SCAN_LIMIT = 10000;
const RESTORED_KEEP_MS = 30 * 86400000;
const EXPIRED_MIN_AGE_MS = 86400000;
const MAX_HISTORY = 100;
const MAX_RESULTS = 200;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$/;
const RULE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const KINDS = new Set(['clean', 'update', 'restore']);
const ACTIONS = new Set(['archived', 'restored', 'deleted', 'skipped', 'expired', 'conflict', 'kept', 'error', 'updated', 'purged']);
const STATUSES = new Set(['pending', 'archived', 'restored', 'missing', 'conflict']);
const PROTECTED = new Set([
  'memory.md', 'claude.md', 'agents.md', 'gemini.md', 'auth.json', '.credentials.json',
  'credentials.json', 'credentials', 'settings.json', 'settings.local.json', 'config.toml',
  'config.json', 'config.yaml', '.env', '.npmrc', '.netrc',
]);
const LOCK_NAME = 'maintenance.lock';
const DEFAULT_STALE_MS = 60000;

const USAGE = `usage:
  maintenance.js archive-put --rule ID --root ROOT --source FILE --dest FILE [--json]
  maintenance.js archive-list [--json] [--limit N] [--offset N]
  maintenance.js archive-gc [--dry-run] [--json]
  maintenance.js restore ID [--dry-run] [--json]
  maintenance.js history-add --kind clean|update|restore [--file PATH] [--dry-run] [--json]
  maintenance.js history [--json] [--limit N]
  maintenance.js run-clean -- /bin/bash <bin>/clean_ai_leftovers.sh ARG...
  maintenance.js run-clean -- powershell.exe -NoProfile -NonInteractive -File <bin>/clean_ai_leftovers.ps1 ARG...`;

function fail(status, error, extra) {
  const e = new Error(error);
  e.status = status;
  Object.assign(e, extra);
  return e;
}

function envPaths() {
  const { home, aicmHome } = common.paths();
  const temp = process.env.TMPDIR || process.env.TEMP || process.env.TMP || (process.platform === 'win32' ? '' : '/tmp');
  return {
    home: path.resolve(home),
    aicmHome: path.resolve(aicmHome),
    temp: temp ? path.resolve(temp) : '',
  };
}

function staleMs() {
  const n = Number(process.env.AICM_LOCK_STALE_MS);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_STALE_MS;
}

function noFollow() {
  return fs.constants.O_NOFOLLOW || 0;
}

function isInside(parent, child) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel !== '' && rel !== '.' && rel !== '..' && !rel.startsWith('..' + path.sep) && !path.isAbsolute(rel);
}

function tempLooksUsable(realTemp, realHome) {
  if (!realTemp || !realHome) return false;
  const root = path.parse(realTemp).root;
  if (realTemp === root || realTemp === realHome) return false;
  // Temp must not contain HOME (temp=/tmp, home=/tmp/home) and must not sit inside HOME.
  if (isInside(realTemp, realHome) || isInside(realHome, realTemp)) return false;
  const base = path.basename(realTemp).toLowerCase();
  if (base === 'tmp' || base === 'temp' || base === 't') return true;
  const n = realTemp.replace(/\\/g, '/').toLowerCase();
  if (n === '/tmp' || n.startsWith('/tmp/') || n.startsWith('/private/tmp/') || n.startsWith('/var/folders/') || n.startsWith('/private/var/folders/')) return true;
  if (process.platform === 'win32') {
    const local = process.env.LOCALAPPDATA ? path.resolve(process.env.LOCALAPPDATA).replace(/\\/g, '/').toLowerCase() : '';
    if (local && (n === local || n.startsWith(local + '/'))) return true;
  }
  return false;
}

function existingReal(p) {
  try { return fs.realpathSync(p); } catch { return null; }
}

function anchorFor(p) {
  const { home, temp } = envPaths();
  const resolved = path.resolve(p);
  if (resolved === home) return { ok: false, status: 'refused', error: 'path is HOME' };
  if (isInside(home, resolved)) return { ok: true, anchor: home };
  const realHome = existingReal(home);
  const realTemp = temp ? existingReal(temp) : null;
  if (realTemp && realHome && tempLooksUsable(realTemp, realHome)) {
    const logicalTemp = path.resolve(temp);
    if (resolved === logicalTemp || resolved === realTemp) return { ok: false, status: 'refused', error: 'path is the temp root' };
    if (isInside(realTemp, resolved)) return { ok: true, anchor: realTemp };
    if (isInside(logicalTemp, resolved) || (existingReal(path.dirname(resolved)) && isInside(realTemp, existingReal(path.dirname(resolved)) || resolved))) {
      if (isInside(logicalTemp, resolved)) return { ok: true, anchor: logicalTemp };
    }
  }
  return { ok: false, status: 'refused', error: 'path is outside HOME and temp' };
}

// Symlink at or below `start`, down to but not including `anchor`, unless includeAnchor.
// Missing components are skipped. macOS /var aliases sit above HOME and temp, so they are not walked.
function findLink(start, anchor, includeAnchor) {
  const stop = path.resolve(anchor);
  const chain = [];
  let cur = path.resolve(start);
  while (cur !== stop) {
    chain.push(cur);
    const parent = path.dirname(cur);
    if (parent === cur) return cur;
    cur = parent;
  }
  if (includeAnchor) chain.push(stop);
  for (let i = chain.length - 1; i >= 0; i--) {
    let st;
    try { st = fs.lstatSync(chain[i]); } catch (e) {
      if (e.code === 'ENOENT') continue;
      throw e;
    }
    if (st.isSymbolicLink()) return chain[i];
  }
  return null;
}

function pathAllowed(p) {
  const loc = anchorFor(p);
  if (!loc.ok) return loc;
  const link = findLink(p, loc.anchor, false);
  if (link) return { ok: false, status: 'refused', error: `symlink at ${link}` };
  const realAnchor = existingReal(loc.anchor);
  if (!realAnchor) return { ok: false, status: 'refused', error: 'anchor is missing' };
  let probe = path.resolve(p);
  const missing = [];
  while (!fs.existsSync(probe) && probe !== loc.anchor) {
    missing.push(path.basename(probe));
    probe = path.dirname(probe);
  }
  const realProbe = existingReal(probe);
  if (!realProbe) return { ok: false, status: 'refused', error: 'path is missing' };
  const rel = path.relative(realAnchor, realProbe);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return { ok: false, status: 'refused', error: 'path escapes its root' };
  return { ok: true, anchor: loc.anchor };
}

function isProtectedPath(p) {
  const base = path.basename(p).toLowerCase();
  if (PROTECTED.has(base)) return true;
  if (base.endsWith('.env') || base.endsWith('.pem') || base.endsWith('.key')) return true;
  if (/^id_(rsa|ed25519|ecdsa|dsa)/.test(base)) return true;
  const parts = p.replace(/\\/g, '/').split('/');
  return parts.some((seg) => seg.toLowerCase() === 'memory');
}

function isSqliteFamily(file) {
  const base = path.basename(file).toLowerCase();
  return /\.(sqlite3?|db)(-(wal|shm|journal))?$/.test(base);
}

function isCodexNative(meta) {
  const rule = String(meta.rule || '');
  if (rule.toLowerCase() === 'codex') return true;
  const base = path.basename(String(meta.original || meta.source || meta.stored || '')).toLowerCase();
  if (base.startsWith('rollout-')) return true;
  if (/^state_\d+\.sqlite/.test(base)) return true;
  const norm = [meta.original, meta.source, meta.stored].filter(Boolean).join('/').replace(/\\/g, '/').toLowerCase();
  return norm.includes('/.codex/sessions/') || norm.includes('/archived_sessions/') || norm.includes('/.codex/archived_sessions/');
}

function validateStored(stored) {
  if (typeof stored !== 'string' || stored.length < 3 || stored.length > 2048) return false;
  if (stored.includes('\\') || stored.includes('\0') || stored.includes(':') || /[\r\n]/.test(stored)) return false;
  if (path.posix.isAbsolute(stored) || path.win32.isAbsolute(stored)) return false;
  const parts = stored.split('/');
  if (parts.length < 2) return false;
  if (parts.some((seg) => !seg || seg === '.' || seg === '..')) return false;
  return RULE_RE.test(parts[0]);
}

function rawOriginalOk(p) {
  if (typeof p !== 'string' || p.length < 2 || p.length > 4096 || /[\0\r\n]/.test(p)) return false;
  const parts = p.split(/[\\/]/);
  if (parts.some((seg) => seg === '.' || seg === '..')) return false;
  if (process.platform === 'win32') {
    if (!path.win32.isAbsolute(p)) return false;
  } else if (p.includes('\\') || p.includes(':') || !path.isAbsolute(p)) return false;
  return path.resolve(p) === p.replace(/[\\/]+$/, '') || path.resolve(p) === p;
}

function safeAicm(contextHome) {
  const env = envPaths();
  if (contextHome !== undefined) env.aicmHome = path.resolve(contextHome);
  const loc = anchorFor(env.aicmHome);
  if (!loc.ok) return { ok: false, status: 'refused', error: `AICM_HOME: ${loc.error}` };
  if (findLink(env.aicmHome, loc.anchor, false)) return { ok: false, status: 'refused', error: 'AICM_HOME is linked or has a linked ancestor' };
  return { ok: true, ...env, anchor: loc.anchor };
}

function ensureDir(dir, anchor) {
  const resolved = path.resolve(dir);
  const root = path.resolve(anchor);
  if (resolved !== root && !isInside(root, resolved)) throw fail('refused', `refusing to create ${dir}`);
  const chain = [];
  let cur = resolved;
  while (cur !== root) {
    chain.push(cur);
    const parent = path.dirname(cur);
    if (parent === cur) throw fail('refused', 'path escaped its anchor');
    cur = parent;
  }
  chain.push(root);
  chain.reverse();
  for (const p of chain) {
    let st;
    try { st = fs.lstatSync(p); } catch (e) {
      if (e.code !== 'ENOENT') throw e;
      fs.mkdirSync(p);
      st = fs.lstatSync(p);
    }
    if (st.isSymbolicLink() || !st.isDirectory()) throw fail('refused', `not a real directory: ${p}`);
  }
  return resolved;
}

function fsyncDir(dir) {
  let fd;
  try { fd = fs.openSync(dir, 'r'); fs.fsyncSync(fd); } catch { /* directories on some platforms */ }
  finally { if (fd != null) try { fs.closeSync(fd); } catch { /* ignore */ } }
}

function atomicWrite(file, text) {
  if (Buffer.byteLength(text) > MAX_MANIFEST_BYTES) throw fail('refused', 'record too large');
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`);
  let fd = null;
  const dropTmp = () => { try { if (fd != null) fs.closeSync(fd); } catch { /* ignore */ } fd = null; try { fs.unlinkSync(tmp); } catch { /* ignore */ } };
  try {
    fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | noFollow(), 0o600);
    fs.writeSync(fd, text);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = null;
    let st = null;
    try { st = fs.lstatSync(file); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (st && st.isSymbolicLink()) throw fail('refused', 'refusing linked metadata');
    if (st && !st.isFile()) throw fail('refused', 'manifest path is not a regular file');
    fs.renameSync(tmp, file);
    fsyncDir(dir);
  } catch (e) {
    dropTmp();
    throw e;
  }
}

function readNoFollow(file, max) {
  const st = fs.lstatSync(file);
  if (st.isSymbolicLink()) throw fail('refused', 'refusing linked metadata');
  if (!st.isFile()) throw fail('refused', 'metadata is not a regular file');
  if (st.size > max) throw fail('refused', 'metadata exceeds size bound');
  const fd = fs.openSync(file, fs.constants.O_RDONLY | noFollow());
  try {
    const now = fs.fstatSync(fd);
    if (!now.isFile() || now.size !== st.size) throw fail('refused', 'metadata changed while reading');
    return fs.readFileSync(fd, 'utf8');
  } finally { fs.closeSync(fd); }
}

function indexDir(aicmHome) { return path.join(aicmHome, 'state', 'archive-index'); }
function historyDir(aicmHome) { return path.join(aicmHome, 'state', 'history'); }
function archiveRoot(aicmHome) { return path.join(aicmHome, 'archive'); }
function lockDir(aicmHome) { return path.join(aicmHome, 'state', LOCK_NAME); }

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try { process.kill(pid, 0); return true; } catch (e) {
    if (e.code === 'ESRCH') return false;
    return true;
  }
}

function lockInfo(dir) {
  let dirSt;
  try { dirSt = fs.lstatSync(dir); } catch { return { corrupt: true, mtimeMs: Date.now() }; }
  const mtimeMs = dirSt.mtimeMs;
  const owner = path.join(dir, 'owner.json');
  let st;
  try { st = fs.lstatSync(owner); } catch { return { corrupt: true, mtimeMs }; }
  if (st.isSymbolicLink() || !st.isFile() || st.size > 4096) return { corrupt: true, mtimeMs };
  try {
    const j = JSON.parse(readNoFollow(owner, 4096));
    return { pid: j.pid, lease: j.lease, createdAt: j.createdAt, mtimeMs, corrupt: false };
  } catch { return { corrupt: true, mtimeMs }; }
}

function shouldReclaim(dir) {
  const info = lockInfo(dir);
  if (!info.corrupt) {
    // A live owner is never reclaimed because of age.
    if (pidAlive(info.pid) !== false) return false;
    return true;
  }
  return Date.now() - info.mtimeMs >= staleMs();
}

function acquireLock(aicmHome, { contextHome } = {}) {
  const gate = safeAicm(contextHome);
  if (!gate.ok) throw fail(gate.status, gate.error);
  if (path.resolve(aicmHome) !== gate.aicmHome) throw fail('refused', 'lock home mismatch');
  ensureDir(path.join(gate.aicmHome, 'state'), gate.aicmHome);
  const dir = lockDir(gate.aicmHome);
  if (path.basename(dir) !== LOCK_NAME) throw fail('refused', 'bad lock path');
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      fs.mkdirSync(dir);
      const born = fs.lstatSync(dir);
      if (born.isSymbolicLink() || !born.isDirectory()) throw fail('refused', 'lock path is not a directory');
      const lease = crypto.randomBytes(32).toString('hex');
      atomicWrite(path.join(dir, 'owner.json'), JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString(), lease }));
      const id = { dev: born.dev, ino: born.ino };
      return {
        dir,
        lease,
        release() {
          try {
            const now = fs.lstatSync(dir);
            if (now.isSymbolicLink() || !now.isDirectory() || now.dev !== id.dev || now.ino !== id.ino) return;
            const info = lockInfo(dir);
            if (info.pid !== process.pid) return;
            fs.rmSync(dir, { recursive: true, force: true });
          } catch { /* already gone */ }
        },
      };
    } catch (e) {
      if (e.status === 'refused') throw e;
      if (e.code !== 'EEXIST') {
        try { if (fs.lstatSync(dir).isDirectory() && !fs.existsSync(path.join(dir, 'owner.json'))) fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
        throw e;
      }
      const st = fs.lstatSync(dir);
      if (st.isSymbolicLink() || !st.isDirectory()) throw fail('refused', 'lock path is not a directory');
      if (!shouldReclaim(dir)) throw fail('locked', 'maintenance lock is held');
      const grave = path.join(path.dirname(dir), `${LOCK_NAME}.stale-${process.pid}-${attempt}`);
      try { fs.renameSync(dir, grave); } catch { throw fail('locked', 'maintenance lock is held'); }
      fs.rmSync(grave, { recursive: true, force: true });
    }
  }
  throw fail('locked', 'maintenance lock is held');
}

function leaseValid() {
  const token = process.env.AICM_MAINTENANCE_LEASE || '';
  const ownerPid = Number(process.env.AICM_MAINTENANCE_OWNER);
  if (!/^[a-f0-9]{64}$/.test(token) || !Number.isInteger(ownerPid) || ownerPid <= 0) return false;
  const gate = safeAicm();
  if (!gate.ok) return false;
  const state = path.join(gate.aicmHome, 'state');
  const dir = lockDir(gate.aicmHome);
  try {
    const stateSt = fs.lstatSync(state);
    if (stateSt.isSymbolicLink() || !stateSt.isDirectory()) return false;
    if (findLink(dir, gate.aicmHome, true)) return false;
    const info = JSON.parse(readNoFollow(path.join(dir, 'owner.json'), 4096));
    if (info.lease !== token || info.pid !== ownerPid) return false;
    if (pidAlive(info.pid) !== true) return false;
  } catch { return false; }
  return true;
}

function withLock(fn, opts = {}) {
  const gate = safeAicm();
  if (!gate.ok) return gate;
  // archive-put passes honorLease so a cleanup child does not lock against run-clean.
  if (opts.honorLease && leaseValid()) return fn(gate);
  let lock;
  try { lock = acquireLock(gate.aicmHome); } catch (e) {
    return { ok: false, status: e.status || 'refused', error: e.message, recoverable: false };
  }
  try { return fn(gate); } finally { lock.release(); }
}

function newId(prefix) {
  return prefix + Date.now().toString(16) + crypto.randomBytes(8).toString('hex');
}

function toStored(root, dest) {
  const rel = path.relative(root, dest);
  return rel.split(path.sep).join('/');
}

function storedToAbs(root, stored) {
  if (!validateStored(stored)) return null;
  return path.join(root, ...stored.split('/'));
}

function discardFile(file) {
  try {
    const st = fs.lstatSync(file);
    if (st.isSymbolicLink() || !st.isFile()) return;
    fs.unlinkSync(file);
  } catch { /* ignore */ }
}

function sameIdentity(a, b) {
  return !!a && !!b && a.isFile() && b.isFile() && !a.isSymbolicLink() && !b.isSymbolicLink()
    && a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs;
}

function copyExclusive(src, dest) {
  const before = fs.lstatSync(src);
  if (before.isSymbolicLink() || !before.isFile()) throw fail('refused', 'source is not a regular file');
  const inFd = fs.openSync(src, fs.constants.O_RDONLY | noFollow());
  let outFd = null;
  let created = false;
  try {
    const st = fs.fstatSync(inFd);
    if (!sameIdentity(before, st)) throw fail('refused', 'source changed before copy');
    outFd = fs.openSync(dest, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | noFollow(), 0o600);
    created = true;
    const buf = Buffer.alloc(64 * 1024);
    let total = 0;
    while (total < st.size) {
      const n = fs.readSync(inFd, buf, 0, buf.length, null);
      if (n === 0) break;
      let off = 0;
      while (off < n) off += fs.writeSync(outFd, buf, off, n - off);
      total += n;
    }
    if (total !== st.size) throw fail('refused', 'short copy');
    fs.fsyncSync(outFd);
    const now = fs.lstatSync(src);
    if (!sameIdentity(before, now)) {
      throw fail('refused', 'source changed during copy', { keepCopy: true });
    }
  } catch (e) {
    if (created && !e.keepCopy) {
      try { fs.closeSync(outFd); } catch { /* ignore */ }
      outFd = null;
      discardFile(dest);
    }
    if (e.code === 'EEXIST') throw fail('conflict', 'destination exists');
    throw e;
  } finally {
    try { fs.closeSync(inFd); } catch { /* ignore */ }
    if (outFd != null) try { fs.closeSync(outFd); } catch { /* ignore */ }
  }
}

function placeExclusive(src, dest) {
  try {
    fs.linkSync(src, dest);
    const a = fs.lstatSync(src);
    const b = fs.lstatSync(dest);
    if (a.isSymbolicLink() || b.isSymbolicLink() || !a.isFile() || a.ino !== b.ino || a.dev !== b.dev) {
      discardFile(dest);
      throw fail('refused', 'hard link failed the safety check');
    }
    return 'link';
  } catch (e) {
    if (e.status) throw e;
    if (e.code === 'EEXIST') throw fail('conflict', 'destination exists');
    if (!['EXDEV', 'EPERM', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS', 'EINVAL'].includes(e.code)) throw e;
  }
  copyExclusive(src, dest);
  return 'copy';
}

function moveNoOverwrite(src, dest) {
  const before = fs.lstatSync(src);
  if (before.isSymbolicLink() || !before.isFile()) throw fail('refused', 'source is not a regular file');
  placeExclusive(src, dest);
  fsyncDir(path.dirname(dest));
  try {
    const srcSt = fs.lstatSync(src);
    const destSt = fs.lstatSync(dest);
    if (destSt.isSymbolicLink() || !destSt.isFile() || destSt.size !== before.size) throw fail('refused', 'path changed during move');
    if (!sameIdentity(before, srcSt)) throw fail('refused', 'source changed during move', { keepCopy: true });
    fs.unlinkSync(src);
  } catch (e) {
    let stillOriginal = false;
    try { stillOriginal = sameIdentity(before, fs.lstatSync(src)); } catch { stillOriginal = false; }
    // A replacement at the source path stays. Drop the new copy only when the
    // original inode is still there (the move did not finish). If that inode is
    // gone, the destination is the only remaining copy.
    if (stillOriginal && !e.keepCopy) discardFile(dest);
    throw e;
  }
}

function checkOrdinary(source) {
  let st;
  try { st = fs.lstatSync(source); } catch (e) {
    if (e.code === 'ENOENT') return { ok: false, status: 'missing', recoverable: true, error: 'source is missing' };
    throw e;
  }
  if (st.isSymbolicLink() || !st.isFile()) return { ok: false, status: 'refused', error: 'source is not a regular file' };
  return { ok: true, size: st.size };
}

function prepareArchive(opts) {
  const rule = opts.rule;
  const root = opts.root;
  const source = opts.source;
  const dest = opts.dest;
  if (!RULE_RE.test(rule || '')) return { ok: false, status: 'refused', error: 'invalid rule id' };
  if (!root || !source || !dest) return { ok: false, status: 'refused', error: 'root, source, and dest are required' };
  const gate = safeAicm();
  if (!gate.ok) return gate;
  const rootOk = pathAllowed(root);
  if (!rootOk.ok) return rootOk;
  const srcOk = pathAllowed(source);
  if (!srcOk.ok) return srcOk;
  if (!isInside(path.resolve(root), path.resolve(source))) return { ok: false, status: 'refused', error: 'source is outside the rule root' };
  if (isInside(gate.aicmHome, path.resolve(source)) || path.resolve(source) === gate.aicmHome) {
    return { ok: false, status: 'refused', error: 'refusing to archive AICM_HOME' };
  }
  if (isProtectedPath(source) || isSqliteFamily(source) || isCodexNative({ rule, source, original: source })) {
    return { ok: false, status: 'refused', error: 'protected, sqlite, or Codex-native file' };
  }
  const arch = archiveRoot(gate.aicmHome);
  if (!isInside(arch, path.resolve(dest))) return { ok: false, status: 'refused', error: 'dest is outside AICM_HOME/archive' };
  const stored = toStored(arch, path.resolve(dest));
  if (!validateStored(stored) || stored.split('/')[0] !== rule) return { ok: false, status: 'refused', error: 'dest does not match the rule' };
  if (findLink(dest, gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'destination or AICM_HOME is linked' };
  let rootSt;
  try { rootSt = fs.lstatSync(root); } catch { return { ok: false, status: 'refused', error: 'root is missing' }; }
  if (rootSt.isSymbolicLink() || !rootSt.isDirectory()) return { ok: false, status: 'refused', error: 'root is not a real directory' };
  return { ok: true, gate, stored, arch, source: path.resolve(source), dest: path.resolve(dest), root: path.resolve(root), rule };
}

function archivePut(opts) {
  const plan = prepareArchive(opts || {});
  if (!plan.ok) return plan;
  const have = checkOrdinary(plan.source);
  if (!have.ok) return have;
  let destSt = null;
  try { destSt = fs.lstatSync(plan.dest); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (destSt) return { ok: false, status: 'conflict', error: 'destination exists', recoverable: true };
  return withLock(() => {
    let manifest = null;
    let moved = false;
    try {
      const again = prepareArchive(opts);
      if (!again.ok) return again;
      const src = checkOrdinary(again.source);
      if (!src.ok) return src;
      try { if (fs.lstatSync(again.dest)) return { ok: false, status: 'conflict', error: 'destination exists', recoverable: true }; }
      catch (e) { if (e.code !== 'ENOENT') throw e; }
      ensureDir(again.arch, again.gate.aicmHome);
      ensureDir(path.dirname(again.dest), again.arch);
      if (findLink(again.dest, again.gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'destination linked after create' };
      const parentReal = existingReal(path.dirname(again.dest));
      const archReal = existingReal(again.arch);
      if (!parentReal || !archReal || !(parentReal === archReal || isInside(archReal, parentReal))) {
        return { ok: false, status: 'refused', error: 'destination escapes the archive' };
      }
      const dir = indexDir(again.gate.aicmHome);
      ensureDir(dir, again.gate.aicmHome);
      if (findLink(dir, again.gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'archive index is linked' };
      const id = newId('m');
      const record = {
        id, original: again.source, stored: again.stored, rule: again.rule,
        archivedAt: new Date().toISOString(), size: src.size, status: 'pending',
      };
      manifest = path.join(dir, `${id}.json`);
      atomicWrite(manifest, JSON.stringify(record));
      const src2 = checkOrdinary(again.source);
      if (!src2.ok || src2.size !== src.size) {
        discardFile(manifest);
        return src2.ok ? { ok: false, status: 'refused', error: 'source changed', recoverable: true } : src2;
      }
      moveNoOverwrite(again.source, again.dest);
      moved = true;
      record.status = 'archived';
      atomicWrite(manifest, JSON.stringify(record));
      return { ok: true, id, status: 'archived', stored: again.stored, original: again.source, size: src.size, rule: again.rule };
    } catch (e) {
      let srcStill = false;
      try { srcStill = fs.lstatSync(plan.source).isFile(); } catch { srcStill = false; }
      if (manifest && srcStill && !moved) discardFile(manifest);
      return { ok: false, status: e.status || 'refused', error: e.message, recoverable: srcStill || !moved };
    }
  }, { honorLease: true });
}

function parseManifest(file, id, aicmHome) {
  let text;
  try { text = readNoFollow(file, MAX_MANIFEST_BYTES); } catch (e) {
    return { problem: { file: path.basename(file), error: e.message } };
  }
  let data;
  try { data = JSON.parse(text); } catch { return { problem: { file: path.basename(file), error: 'malformed' } }; }
  if (!data || typeof data !== 'object' || Array.isArray(data)) return { problem: { file: id, error: 'malformed' } };
  const stored = data.stored;
  const original = data.original;
  if (data.id !== id || !ID_RE.test(id)) return { problem: { file: id, error: 'id mismatch' } };
  if (!validateStored(stored) || !RULE_RE.test(data.rule) || stored.split('/')[0] !== data.rule) {
    return { problem: { file: id, error: 'bad stored path' } };
  }
  if (!rawOriginalOk(original) || typeof data.archivedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(data.archivedAt)) {
    return { problem: { file: id, error: 'bad original or time' } };
  }
  if (!Number.isInteger(data.size) || data.size < 0 || !STATUSES.has(data.status)) {
    return { problem: { file: id, error: 'bad size or status' } };
  }
  const arch = archiveRoot(aicmHome);
  const abs = storedToAbs(arch, stored);
  if (!abs || path.resolve(abs) !== abs && path.resolve(abs) !== path.normalize(abs)) {
    return { problem: { file: id, error: 'bad stored path' } };
  }
  if (!isInside(arch, abs)) return { problem: { file: id, error: 'stored escapes archive' } };
  return {
    item: {
      id, original, stored, rule: data.rule, archivedAt: data.archivedAt, size: data.size, status: data.status,
    },
  };
}

function originalAbsent(p) {
  try { fs.lstatSync(p); return false; } catch (e) { return e.code === 'ENOENT'; }
}

function storedMatches(item, aicmHome) {
  const abs = storedToAbs(archiveRoot(aicmHome), item.stored);
  if (!abs) return null;
  try {
    const st = fs.lstatSync(abs);
    if (st.isSymbolicLink() || !st.isFile() || st.size !== item.size) return null;
    return abs;
  } catch { return null; }
}

function displayStatus(item, aicmHome) {
  // A crash after the copy but before the manifest was marked archived: the
  // stored file matches and the original path is empty. List it as pending and
  // recoverable. Do not guess a path for legacy files with no manifest.
  if (item.status === 'pending' || item.status === 'missing') {
    if (storedMatches(item, aicmHome) && originalAbsent(item.original)) return 'pending';
    return item.status;
  }
  if (item.status !== 'archived') return item.status;
  const abs = storedToAbs(archiveRoot(aicmHome), item.stored);
  try {
    const st = fs.lstatSync(abs);
    if (st.isSymbolicLink() || !st.isFile()) return 'unsafe';
    return 'archived';
  } catch (e) {
    if (e.code === 'ENOENT') return 'expired';
    return 'unsafe';
  }
}

// Tests may lower the limits (never raise them) to reach the truncation paths with few files.
function limitFromEnv(name, max) {
  const n = Number(process.env[name]);
  return Number.isInteger(n) && n > 0 && n < max ? n : max;
}

// Index manifest names, newest first (an id starts with its creation time in hex). null when there is no index.
function indexNames(aicmHome) {
  const dir = indexDir(aicmHome);
  let st;
  try { st = fs.lstatSync(dir); } catch (e) {
    if (e.code === 'ENOENT') return { names: [] };
    throw e;
  }
  if (st.isSymbolicLink() || !st.isDirectory()) return { ok: false, status: 'refused', error: 'archive index is not a real directory' };
  if (findLink(dir, aicmHome, true)) return { ok: false, status: 'refused', error: 'archive index is linked' };
  const names = fs.readdirSync(dir).filter((n) => n.endsWith('.json') && !n.startsWith('.'));
  names.sort();
  names.reverse();
  return { dir, names };
}

// One index entry: { item } (with its display status), { problem }, or {} for an entry that is not a file.
function readIndexEntry(dir, name, aicmHome) {
  const id = name.slice(0, -5);
  const file = path.join(dir, name);
  let lst;
  try { lst = fs.lstatSync(file); } catch { return { problem: { file: name, error: 'unreadable' } }; }
  if (lst.isSymbolicLink()) return { problem: { file: name, error: 'linked manifest' } };
  if (!lst.isFile()) return {};
  const parsed = parseManifest(file, id, aicmHome);
  if (parsed.problem) return parsed;
  return { item: parsed.item, stat: lst };
}

function listManifests(aicmHome, opts = {}) {
  const listed = indexNames(aicmHome);
  if (listed.ok === false) return listed;
  const offset = opts.offset || 0;
  const limit = opts.limit || MAX_ENTRIES;
  const page = listed.names.slice(offset, offset + limit);
  const items = [];
  const problems = [];
  for (const name of page) {
    const entry = readIndexEntry(listed.dir, name, aicmHome);
    if (entry.problem) problems.push(entry.problem);
    else if (entry.item) {
      const shown = displayStatus(entry.item, aicmHome);
      const row = { ...entry.item, status: shown, diskStatus: entry.item.status };
      if ((entry.item.status === 'pending' || entry.item.status === 'missing') && shown === 'pending' && storedMatches(entry.item, aicmHome)) row.recoverable = true;
      items.push(row);
    }
  }
  const next = offset + page.length < listed.names.length ? offset + page.length : null;
  return { items, problems, dir: listed.dir, names: listed.names, pageNames: page, total: listed.names.length, offset, limit, nextOffset: next };
}

// Stored paths of every readable manifest, or null when the index is larger than the scan limit (then
// no archive file can be called legacy).
function indexedStored(aicmHome, listed) {
  if (listed.total > limitFromEnv('AICM_ARCHIVE_SCAN_LIMIT', INDEX_SCAN_LIMIT)) return null;
  const known = new Set(listed.items.map((i) => i.stored));
  const onPage = new Set(listed.pageNames);
  for (const name of listed.names) {
    if (onPage.has(name)) continue;
    const entry = readIndexEntry(listed.dir, name, aicmHome);
    if (entry.item) known.add(entry.item.stored);
  }
  return known;
}

// Files under archive/ that no manifest points at. complete:false when the walk stopped at its bound.
function listLegacy(aicmHome, known) {
  const root = archiveRoot(aicmHome);
  let st;
  try { st = fs.lstatSync(root); } catch (e) {
    if (e.code === 'ENOENT') return { items: [], complete: true };
    throw e;
  }
  if (st.isSymbolicLink() || !st.isDirectory()) return { items: [{ status: 'unsafe', note: 'archive root is not a real directory' }], complete: true };
  const out = [];
  const walkLimit = limitFromEnv('AICM_ARCHIVE_WALK_LIMIT', LEGACY_WALK_LIMIT);
  let visited = 0;
  let complete = true;
  const walk = (dir) => {
    if (!complete) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const ent of entries) {
      if (++visited > walkLimit || out.length >= MAX_ENTRIES) { complete = false; return; }
      const p = path.join(dir, ent.name);
      if (ent.isSymbolicLink()) continue;
      if (ent.isDirectory()) walk(p);
      else if (ent.isFile()) {
        const stored = toStored(root, p);
        if (!known.has(stored)) out.push({ status: 'legacy', stored, note: 'manual restore' });
      }
      if (!complete) return;
    }
  };
  walk(root);
  return { items: out, complete };
}

// opts.limit (1..10000, default 10000) and opts.offset (default 0) page through the index, newest first.
function archiveList(opts = {}) {
  const offset = opts.offset == null ? 0 : opts.offset;
  const limit = opts.limit == null ? MAX_ENTRIES : opts.limit;
  if (!Number.isInteger(offset) || offset < 0) return { ok: false, status: 'usage', error: 'offset must be a whole number' };
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_ENTRIES) return { ok: false, status: 'usage', error: `limit must be an integer from 1 to ${MAX_ENTRIES}` };
  const gate = safeAicm();
  if (!gate.ok) return gate;
  if (findLink(gate.aicmHome, gate.anchor, false)) return { ok: false, status: 'refused', error: 'AICM_HOME is linked' };
  let index;
  try { index = listManifests(gate.aicmHome, { offset, limit }); } catch (e) {
    return { ok: false, status: 'refused', error: e.message };
  }
  if (index.ok === false) return index;
  const legacyInfo = { listed: offset === 0, complete: false };
  let legacy = [];
  if (offset === 0) {
    let known = null;
    try { known = indexedStored(gate.aicmHome, index); } catch (e) { index.problems.push({ file: 'archive-index', error: e.message }); }
    if (!known) {
      legacyInfo.reason = 'index-too-large';
      index.problems.push({ file: 'archive', error: 'the archive index is too large to tell legacy files apart; none are listed (run: aicm archive gc)' });
    } else {
      try {
        const walked = listLegacy(gate.aicmHome, known);
        legacy = walked.items;
        legacyInfo.complete = walked.complete;
        if (!walked.complete) {
          legacyInfo.reason = 'walk-limit';
          index.problems.push({ file: 'archive', error: 'the archive folder is too large to list every legacy file; the list is cut short' });
        }
      } catch (e) {
        legacyInfo.reason = 'error';
        index.problems.push({ file: 'archive', error: e.message });
      }
    }
  }
  return {
    ok: true,
    items: index.items.concat(legacy),
    problems: index.problems,
    index: {
      total: index.total, offset, limit, returned: index.items.length, nextOffset: index.nextOffset,
      complete: offset === 0 && index.nextOffset === null,
    },
    legacy: legacyInfo,
  };
}

// The dated archive folder of a record (archive/<rule>/<yyyymmdd>) is gone; false when unsure.
function dayFolderGone(item, aicmHome) {
  const parts = item.stored.split('/');
  if (parts.length < 3 || !/^\d{8}$/.test(parts[1])) return false;
  try { fs.lstatSync(path.join(archiveRoot(aicmHome), parts[0], parts[1])); return false; } catch (e) { return e.code === 'ENOENT'; }
}

// Why a record can be dropped from the index, or '' to keep it.
function gcReason(entry, aicmHome, now, archiveReal) {
  const item = entry.item;
  if (item.status === 'restored') {
    return now - entry.stat.mtimeMs >= RESTORED_KEEP_MS ? 'restored' : '';
  }
  if (item.status !== 'archived' || !archiveReal) return '';
  const archivedAt = Date.parse(item.archivedAt);
  if (!Number.isFinite(archivedAt) || now - archivedAt < EXPIRED_MIN_AGE_MS) return '';
  if (displayStatus(item, aicmHome) !== 'expired' || !dayFolderGone(item, aicmHome)) return '';
  return 'expired';
}

function archiveGc(opts = {}) {
  const dryRun = !!opts.dryRun;
  const now = opts.now == null ? Date.now() : opts.now;
  const gate = safeAicm();
  if (!gate.ok) return gate;
  if (findLink(gate.aicmHome, gate.anchor, false)) return { ok: false, status: 'refused', error: 'AICM_HOME is linked' };
  const scan = () => {
    const listed = indexNames(gate.aicmHome);
    if (listed.ok === false) return listed;
    let archiveReal = false;
    try { const st = fs.lstatSync(archiveRoot(gate.aicmHome)); archiveReal = st.isDirectory() && !st.isSymbolicLink(); } catch { archiveReal = false; }
    const oldest = listed.names.slice().reverse().slice(0, GC_SCAN_LIMIT);
    const result = { ok: true, dryRun, scanned: oldest.length, total: listed.names.length, pruned: 0, kept: 0, reasons: { expired: 0, restored: 0 }, complete: listed.names.length <= GC_SCAN_LIMIT, errors: [] };
    for (const name of oldest) {
      const entry = readIndexEntry(listed.dir, name, gate.aicmHome);
      const reason = entry.item ? gcReason(entry, gate.aicmHome, now, archiveReal) : '';
      if (!reason) { result.kept++; continue; }
      if (!dryRun) {
        const file = path.join(listed.dir, name);
        try {
          const st = fs.lstatSync(file);
          if (st.isSymbolicLink() || !st.isFile() || st.ino !== entry.stat.ino || st.size !== entry.stat.size || st.mtimeMs !== entry.stat.mtimeMs) { result.kept++; continue; }
          fs.unlinkSync(file);
        } catch (e) {
          if (result.errors.length < 20) result.errors.push({ file: name, error: e.message });
          result.kept++;
          continue;
        }
      }
      result.pruned++;
      result.reasons[reason]++;
    }
    if (!dryRun && result.pruned) fsyncDir(listed.dir);
    return result;
  };
  try {
    if (dryRun) return scan();
    let st;
    try { st = fs.lstatSync(indexDir(gate.aicmHome)); } catch (e) {
      if (e.code === 'ENOENT') return { ok: true, dryRun, scanned: 0, total: 0, pruned: 0, kept: 0, reasons: { expired: 0, restored: 0 }, complete: true, errors: [] };
      throw e;
    }
    if (st.isSymbolicLink() || !st.isDirectory()) return { ok: false, status: 'refused', error: 'archive index is not a real directory' };
    return withLock(scan, { honorLease: true });
  } catch (e) {
    return { ok: false, status: e.status || 'refused', error: e.message };
  }
}

function restore(id, opts = {}) {
  if (!ID_RE.test(id || '')) return { ok: false, status: 'refused', error: 'invalid id' };
  const dryRun = !!opts.dryRun;
  const gate = safeAicm();
  if (!gate.ok) return gate;
  const file = path.join(indexDir(gate.aicmHome), `${id}.json`);
  const readOne = () => {
    if (findLink(path.dirname(file), gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'archive index is linked' };
    let parsed;
    try { parsed = parseManifest(file, id, gate.aicmHome); } catch (e) {
      return { ok: false, status: e.status || 'refused', error: e.message };
    }
    if (parsed.problem) return { ok: false, status: 'refused', error: parsed.problem.error };
    return { ok: true, item: parsed.item };
  };
  const check = readOne();
  if (!check.ok) return check;
  const item = check.item;
  if (isCodexNative(item)) return { ok: false, status: 'refused', error: 'Codex-native records are not restored generically' };
  if (isProtectedPath(item.original) || isSqliteFamily(item.original)) return { ok: false, status: 'refused', error: 'protected destination' };
  const approved = pathAllowed(item.original);
  if (!approved.ok) return approved;
  if (isInside(gate.aicmHome, item.original)) return { ok: false, status: 'refused', error: 'refusing to restore into AICM_HOME' };
  const abs = storedToAbs(archiveRoot(gate.aicmHome), item.stored);
  if (findLink(abs, gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'archived file path is linked' };
  if (item.status === 'restored') {
    let placed = null;
    try { placed = fs.lstatSync(item.original); } catch { placed = null; }
    if (placed && placed.isFile() && !placed.isSymbolicLink() && placed.size === item.size) {
      return { ok: true, status: 'restored', already: true, id, original: item.original, stored: item.stored, dryRun: false };
    }
    return { ok: false, status: 'conflict', error: 'restore already recorded', recoverable: true };
  }
  let destSt = null;
  try { destSt = fs.lstatSync(item.original); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if (destSt) return { ok: false, status: 'conflict', error: 'original path exists', recoverable: true };
  const shown = displayStatus(item, gate.aicmHome);
  const pendingOk = (item.status === 'pending' || item.status === 'missing') && shown === 'pending';
  if (!((item.status === 'archived' && shown === 'archived') || pendingOk)) {
    return { ok: false, status: shown === 'expired' ? 'expired' : 'refused', error: `not restorable (${shown})`, recoverable: shown === 'expired' || shown === 'pending' };
  }
  if (!storedMatches(item, gate.aicmHome)) {
    if (item.status === 'archived') return { ok: false, status: 'expired', error: 'archived file is gone', recoverable: true };
    return { ok: false, status: 'refused', error: 'archived file does not match the manifest' };
  }
  if (findLink(item.original, approved.anchor, false)) return { ok: false, status: 'refused', error: 'original path is linked' };
  if (dryRun) return { ok: true, status: 'would-restore', id, original: item.original, stored: item.stored, dryRun: true };
  return withLock(() => {
    const live = readOne();
    if (!live.ok) return live;
    if (JSON.stringify(live.item) !== JSON.stringify(item)) return { ok: false, status: 'refused', error: 'manifest changed' };
    if (findLink(abs, gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'archived file path is linked' };
    if (findLink(item.original, approved.anchor, false)) return { ok: false, status: 'refused', error: 'original path is linked' };
    if (!storedMatches(live.item, gate.aicmHome)) return { ok: false, status: 'refused', error: 'archived file does not match the manifest' };
    let raced = null;
    try { raced = fs.lstatSync(item.original); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (raced) {
      if (raced.isFile() && !raced.isSymbolicLink() && raced.size === item.size) {
        return { ok: false, status: 'conflict', error: 'original path exists', recoverable: true };
      }
      return { ok: false, status: 'conflict', error: 'original path exists', recoverable: true };
    }
    ensureDir(path.dirname(item.original), approved.anchor);
    if (findLink(item.original, approved.anchor, false)) return { ok: false, status: 'refused', error: 'original path is linked' };
    if (findLink(abs, gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'archived file path is linked' };
    try {
      moveNoOverwrite(abs, item.original);
      const placed = fs.lstatSync(item.original);
      if (!placed.isFile() || placed.isSymbolicLink() || placed.size !== item.size) throw fail('refused', 'restored file mismatch');
      const updated = { ...item, status: 'restored' };
      try {
        atomicWrite(file, JSON.stringify(updated));
      } catch (e) {
        // Bytes are already at the original path. Do not overwrite or delete them.
        return { ok: false, status: 'conflict', error: `restored but manifest not updated: ${e.message}`, recoverable: true };
      }
      return { ok: true, status: 'restored', id, original: item.original, stored: item.stored, dryRun: false };
    } catch (e) {
      return { ok: false, status: e.status || 'refused', error: e.message, recoverable: true };
    }
  });
}

const NAME_RE = /^[A-Za-z][A-Za-z0-9._-]{0,63}$/;
const STATUS_RE = /^[A-Za-z][A-Za-z0-9-]{0,40}$/;
const CATEGORIES = new Set(['sessions', 'cache', 'logs', 'temp', 'other', 'all']);
const RULE_COUNTS = ['candidates', 'candidateBytes', 'removed', 'removedBytes', 'purged', 'purgedBytes', 'inUse', 'files', 'bytes', 'archived', 'archivedBytes', 'restored', 'errors', 'conflicts', 'plannedBytes', 'freedBytes'];
const SUMMARY_KEYS = ['files', 'bytes', 'removed', 'archived', 'restored', 'purged', 'errors', 'conflicts', 'plannedBytes', 'freedBytes', 'archivedBytes'];

function boundedText(value, max) {
  if (typeof value !== 'string' || value.length < 1 || value.length > max || /[\0\r\n]/.test(value)) return null;
  return value;
}

function countValue(n) {
  return Number.isInteger(n) && n >= 0 && n <= 1e15 ? n : null;
}

function humanStatus(value) {
  if (typeof value !== 'string' || value.length < 1 || value.length > 80 || /[\0-\x1f]/.test(value)) return null;
  return value;
}

function sideRecord(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const out = {};
  const p = boundedText(value.path, 4096);
  const version = boundedText(value.version, 512);
  if (p) out.path = p;
  if (version) out.version = version;
  if (Number.isInteger(value.exitCode) && value.exitCode >= -2147483648 && value.exitCode <= 4294967295) out.exitCode = value.exitCode;
  return Object.keys(out).length ? out : null;
}

function sanitizeHistory(kind, input) {
  if (!KINDS.has(kind)) return { ok: false, status: 'usage', error: 'kind must be clean, update, or restore' };
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { ok: false, status: 'refused', error: 'history input must be a JSON object' };
  if (input.kind !== undefined && input.kind !== kind) return { ok: false, status: 'refused', error: 'kind does not match the payload' };
  if (input.dryRun === true || input.dry === true) return { ok: true, skipped: true, reason: 'dry-run' };
  const finishedAt = typeof input.finishedAt === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(input.finishedAt)
    ? input.finishedAt : new Date().toISOString();
  const src = input.summary && typeof input.summary === 'object' && !Array.isArray(input.summary) ? input.summary : {};
  const summary = {};
  for (const key of SUMMARY_KEYS) {
    const n = countValue(src[key]);
    if (n != null) summary[key] = n;
  }
  const categories = [];
  if (Array.isArray(input.categories)) {
    for (const name of input.categories) {
      if (categories.length >= 40) break;
      if (typeof name === 'string' && CATEGORIES.has(name)) categories.push(name);
    }
  }
  const rules = [];
  if (Array.isArray(input.rules)) {
    for (const rule of input.rules) {
      if (rules.length >= 100 || !rule || typeof rule !== 'object') continue;
      const row = {};
      if (typeof rule.id === 'string' && RULE_RE.test(rule.id)) row.id = rule.id;
      if (typeof rule.category === 'string' && CATEGORIES.has(rule.category)) row.category = rule.category;
      const status = humanStatus(rule.status);
      if (status) row.status = status;
      const counts = {};
      if (rule.counts && typeof rule.counts === 'object' && !Array.isArray(rule.counts)) {
        for (const key of RULE_COUNTS) {
          const n = countValue(rule.counts[key]);
          if (n != null) counts[key] = n;
        }
      }
      for (const key of RULE_COUNTS) {
        const n = countValue(rule[key]);
        if (n != null) counts[key] = n;
      }
      if (Object.keys(counts).length) row.counts = counts;
      if (row.id || row.status) rules.push(row);
    }
  }
  const results = [];
  const rows = Array.isArray(input.results) ? input.results.slice(0, MAX_RESULTS) : [];
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const item = {};
    const p = boundedText(row.path, 4096);
    if (p) item.path = p;
    if (ACTIONS.has(row.action)) item.action = row.action;
    if (typeof row.rule === 'string' && RULE_RE.test(row.rule)) item.rule = row.rule;
    if (typeof row.status === 'string' && STATUS_RE.test(row.status)) item.status = row.status;
    const bytes = countValue(row.bytes);
    if (bytes != null) item.bytes = bytes;
    if (typeof row.id === 'string' && (ID_RE.test(row.id) || NAME_RE.test(row.id))) item.id = row.id;
    const command = boundedText(row.command, 128);
    if (command) item.command = command;
    const reason = boundedText(row.reason, 240);
    if (reason) item.reason = reason;
    const before = sideRecord(row.before);
    const after = sideRecord(row.after);
    if (before) item.before = before;
    if (after) item.after = after;
    if (item.path || item.action || item.id || item.status) results.push(item);
  }
  const record = { id: newId('h'), kind, finishedAt, summary, results };
  if (typeof input.ok === 'boolean') record.ok = input.ok;
  if (categories.length) record.categories = categories;
  if (rules.length) record.rules = rules;
  return { ok: true, record };
}

function readHistoryDir(aicmHome) {
  const dir = historyDir(aicmHome);
  let st;
  try { st = fs.lstatSync(dir); } catch (e) {
    if (e.code === 'ENOENT') return { records: [], problems: [] };
    throw e;
  }
  if (st.isSymbolicLink() || !st.isDirectory()) return { ok: false, status: 'refused', error: 'history directory is not real' };
  if (findLink(dir, aicmHome, true)) return { ok: false, status: 'refused', error: 'history directory is linked' };
  const records = [];
  const problems = [];
  for (const name of fs.readdirSync(dir)) {
    if (records.length + problems.length >= MAX_ENTRIES) break;
    if (!name.endsWith('.json') || name.startsWith('.')) continue;
    const id = name.slice(0, -5);
    const file = path.join(dir, name);
    let text;
    try { text = readNoFollow(file, MAX_MANIFEST_BYTES); } catch (e) {
      problems.push({ file: name, error: e.message });
      continue;
    }
    let data;
    try { data = JSON.parse(text); } catch { problems.push({ file: name, error: 'malformed' }); continue; }
    if (!data || data.id !== id || !KINDS.has(data.kind) || typeof data.finishedAt !== 'string') {
      problems.push({ file: name, error: 'malformed' });
      continue;
    }
    const clean = sanitizeHistory(data.kind, data);
    if (!clean.record) { problems.push({ file: name, error: 'malformed' }); continue; }
    records.push({ ...clean.record, id });
  }
  return { records, problems };
}

function historyAdd(kind, input, opts = {}) {
  if (opts.dryRun) return { ok: true, skipped: true, reason: 'dry-run' };
  let parsed = input;
  if (typeof input === 'string') {
    if (Buffer.byteLength(input) > MAX_INPUT) return { ok: false, status: 'refused', error: 'input too large' };
    try { parsed = JSON.parse(stripBom(input)); } catch { return { ok: false, status: 'refused', error: 'malformed JSON' }; }
  }
  const clean = sanitizeHistory(kind, parsed);
  if (!clean.ok || clean.skipped) return clean;
  const gate = safeAicm();
  if (!gate.ok) return gate;
  if (findLink(gate.aicmHome, gate.anchor, false)) return { ok: false, status: 'refused', error: 'AICM_HOME is linked' };
  const state = path.join(gate.aicmHome, 'state');
  try { ensureDir(state, gate.aicmHome); } catch (e) {
    return { ok: false, status: e.status || 'refused', error: e.message };
  }
  const dir = historyDir(gate.aicmHome);
  let existing;
  try { existing = fs.lstatSync(dir); } catch (e) {
    if (e.code !== 'ENOENT') return { ok: false, status: 'refused', error: e.message };
    existing = null;
  }
  if (existing && (existing.isSymbolicLink() || !existing.isDirectory())) {
    return { ok: false, status: 'refused', error: 'history directory is not real' };
  }
  try { ensureDir(dir, gate.aicmHome); } catch (e) {
    return { ok: false, status: e.status || 'refused', error: e.message };
  }
  if (findLink(dir, gate.aicmHome, true)) return { ok: false, status: 'refused', error: 'history directory is linked' };
  const file = path.join(dir, `${clean.record.id}.json`);
  try { atomicWrite(file, JSON.stringify(clean.record)); } catch (e) {
    return { ok: false, status: 'refused', error: e.message, recoverable: true };
  }
  const listed = readHistoryDir(gate.aicmHome);
  if (listed.records) {
    const sorted = listed.records.slice().sort((a, b) => a.finishedAt.localeCompare(b.finishedAt) || a.id.localeCompare(b.id));
    const extra = sorted.length - MAX_HISTORY;
    for (let i = 0; i < extra; i++) {
      const victim = path.join(dir, `${sorted[i].id}.json`);
      try {
        const st = fs.lstatSync(victim);
        if (st.isFile() && !st.isSymbolicLink()) fs.unlinkSync(victim);
      } catch { /* keep going */ }
    }
  }
  return { ok: true, id: clean.record.id, kind, skipped: false };
}

function historyList(opts = {}) {
  const limit = opts.limit == null ? 20 : opts.limit;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    return { ok: false, status: 'usage', error: 'limit must be an integer from 1 to 100' };
  }
  const gate = safeAicm();
  if (!gate.ok) return gate;
  let listed;
  try { listed = readHistoryDir(gate.aicmHome); } catch (e) {
    return { ok: false, status: 'refused', error: e.message };
  }
  if (listed.ok === false) return listed;
  const items = listed.records.slice().sort((a, b) => b.finishedAt.localeCompare(a.finishedAt) || b.id.localeCompare(a.id)).slice(0, limit);
  return { ok: true, items, problems: listed.problems };
}

function flagParser(argv, spec) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { out._.push(...argv.slice(i + 1)); break; }
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const name = a.slice(2);
    if (!Object.prototype.hasOwnProperty.call(spec, name)) return { error: `unknown argument: ${a}` };
    if (spec[name]) { const v = argv[++i]; if (v == null) return { error: `missing value for ${a}` }; out[name] = v; }
    else out[name] = true;
  }
  return out;
}

function asciiJson(value) {
  return JSON.stringify(value).replace(/[^\x00-\x7f]/g, (ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
}

function emit(json, code, payload, text) {
  if (json) console.log(asciiJson(payload));
  else if (code === 0) console.log(text);
  else console.error(text || payload.error || 'failed');
  return code;
}

function cliArchivePut(argv) {
  const args = flagParser(argv, { rule: true, root: true, source: true, dest: true, json: false });
  if (args.error || args._.length) return emit(false, 2, { ok: false, error: args.error || 'unexpected argument' }, USAGE);
  const result = archivePut({ rule: args.rule, root: args.root, source: args.source, dest: args.dest });
  const code = result.ok ? 0 : 1;
  return emit(!!args.json, code, result, result.ok ? `archived ${result.id} ${result.stored}` : `archive-put: ${result.error}`);
}

// A whole number flag value, or undefined when absent; NaN when malformed.
function intFlag(value) {
  if (value == null) return undefined;
  return /^\d{1,9}$/.test(value) ? Number(value) : NaN;
}

function cliArchiveList(argv) {
  const args = flagParser(argv, { json: false, limit: true, offset: true });
  if (args.error || args._.length) return emit(false, 2, { ok: false, error: args.error || 'unexpected argument' }, USAGE);
  const result = archiveList({ limit: intFlag(args.limit), offset: intFlag(args.offset) });
  if (!result.ok) return emit(!!args.json, result.status === 'usage' ? 2 : 1, result, `archive-list: ${result.error}`);
  if (args.json) { console.log(asciiJson(result)); return 0; }
  for (const item of result.items) {
    if (item.status === 'legacy') console.log(`legacy - ${item.stored} manual restore`);
    else console.log(`${item.status} ${item.id} ${item.stored}`);
  }
  for (const p of result.problems) console.log(`problem ${p.file} ${p.error}`);
  if (result.index.nextOffset != null) console.log(`more: ${result.index.total - result.index.nextOffset} older index records; next page: --offset ${result.index.nextOffset}`);
  return 0;
}

function cliArchiveGc(argv) {
  const args = flagParser(argv, { 'dry-run': false, json: false });
  if (args.error || args._.length) return emit(false, 2, { ok: false, error: args.error || 'unexpected argument' }, USAGE);
  const result = archiveGc({ dryRun: !!args['dry-run'] });
  const verb = result.dryRun ? 'would drop' : 'dropped';
  const text = result.ok
    ? `archive index: ${verb} ${result.pruned} of ${result.total} records (${result.reasons.expired} expired, ${result.reasons.restored} restored)${result.complete ? '' : '; more remain, run again'}`
    : `archive-gc: ${result.error}`;
  return emit(!!args.json, result.ok ? 0 : 1, result, text);
}

function cliRestore(argv) {
  const args = flagParser(argv, { 'dry-run': false, json: false });
  if (args.error || args._.length !== 1) return emit(false, 2, { ok: false, error: args.error || 'restore needs one id' }, USAGE);
  const result = restore(args._[0], { dryRun: !!args['dry-run'] });
  const code = result.ok ? 0 : 1;
  const text = result.ok
    ? `${result.dryRun ? 'would restore' : 'restored'} ${result.id} ${result.original}`
    : `restore: ${result.error}`;
  return emit(!!args.json, code, result, text);
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

function readInputFile(file) {
  if (!file || file === '-') {
    const chunks = [];
    let total = 0;
    const buf = Buffer.alloc(8192);
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length, null);
      if (!n) break;
      total += n;
      if (total > MAX_INPUT) throw fail('refused', 'input too large');
      chunks.push(Buffer.from(buf.subarray(0, n)));
    }
    return stripBom(Buffer.concat(chunks).toString('utf8'));
  }
  const st = fs.lstatSync(file);
  if (st.isSymbolicLink() || !st.isFile()) throw fail('refused', 'history file must be a regular file');
  if (st.size > MAX_INPUT) throw fail('refused', 'input too large');
  return stripBom(readNoFollow(file, MAX_INPUT));
}

function cliHistoryAdd(argv) {
  const args = flagParser(argv, { kind: true, file: true, 'dry-run': false, json: false });
  if (args.error || args._.length || !args.kind) return emit(false, 2, { ok: false, error: args.error || 'history-add needs --kind' }, USAGE);
  let raw;
  try { raw = readInputFile(args.file); } catch (e) {
    return emit(!!args.json, 1, { ok: false, status: e.status || 'refused', error: e.message }, `history-add: ${e.message}`);
  }
  const result = historyAdd(args.kind, raw, { dryRun: !!args['dry-run'] });
  const code = result.ok ? 0 : (result.status === 'usage' ? 2 : 1);
  const text = !result.ok ? `history-add: ${result.error}` : (result.skipped ? 'history skipped dry-run' : `history ${result.id}`);
  return emit(!!args.json, code, result, text);
}

function cliHistory(argv) {
  const args = flagParser(argv, { json: false, limit: true });
  if (args.error || args._.length) return emit(false, 2, { ok: false, error: args.error || 'unexpected argument' }, USAGE);
  let limit = 20;
  if (args.limit != null) {
    if (!/^\d+$/.test(args.limit)) return emit(!!args.json, 2, { ok: false, error: 'bad limit' }, 'history: limit must be an integer from 1 to 100');
    limit = Number(args.limit);
  }
  const result = historyList({ limit });
  const code = result.ok ? 0 : (result.status === 'usage' ? 2 : 1);
  if (!result.ok) return emit(!!args.json, code, result, `history: ${result.error}`);
  if (args.json) { console.log(asciiJson(result)); return 0; }
  for (const item of result.items) console.log(`${item.finishedAt} ${item.kind} ${item.id}`);
  for (const p of result.problems) console.log(`malformed ${p.file}`);
  return 0;
}

function cleanScripts() {
  const bin = path.resolve(__dirname, '..', 'bin');
  return {
    sh: path.join(bin, 'clean_ai_leftovers.sh'),
    ps1: path.join(bin, 'clean_ai_leftovers.ps1'),
  };
}

function sameFilePath(a, b) {
  try { return fs.realpathSync(a) === fs.realpathSync(b); } catch { return false; }
}

function forbiddenEngineArg(arg) {
  return /^-c$/i.test(arg) || /^-Command$/i.test(arg) || /^-EncodedCommand$/i.test(arg);
}

function resolveClean(executable, args) {
  if (typeof executable !== 'string' || !path.isAbsolute(executable)) return null;
  if (!Array.isArray(args) || args.some((arg) => typeof arg !== 'string')) return null;
  if (args.some(forbiddenEngineArg)) return null;
  const base = path.basename(executable).toLowerCase();
  const scripts = cleanScripts();
  if (base === 'bash') {
    if (!args.length || !sameFilePath(args[0], scripts.sh)) return null;
    let st;
    try { st = fs.lstatSync(scripts.sh); } catch { return null; }
    if (!st.isFile()) return null;
    return { executable, args };
  }
  if (base === 'powershell.exe' || base === 'pwsh.exe') {
    const flag = (value) => String(value || '').toLowerCase();
    if (flag(args[0]) !== '-noprofile' || flag(args[1]) !== '-noninteractive' || flag(args[2]) !== '-file') return null;
    if (!args[3] || !sameFilePath(args[3], scripts.ps1)) return null;
    let st;
    try { st = fs.lstatSync(scripts.ps1); } catch { return null; }
    if (!st.isFile()) return null;
    return { executable, args };
  }
  return null;
}

function wantsCleanJson(args) {
  return Array.isArray(args) && args.some((arg) => /^--json$/i.test(arg) || /^-json$/i.test(arg));
}

function cleanFailureDoc(error) {
  const text = String(error || 'cleanup refused').replace(/[\0\r\n]/g, ' ').slice(0, 240);
  return {
    schemaVersion: 1,
    dryRun: false,
    categories: [],
    rules: [],
    summary: { plannedBytes: 0, freedBytes: 0, archivedBytes: 0 },
    errors: [text],
    status: 'error',
  };
}

function runClean(executable, args) {
  const spec = resolveClean(executable, args);
  if (!spec) {
    return { ok: false, status: 'refused', error: 'interpreter or cleanup script is not the checkout bin copy', exitCode: 1, spawned: false };
  }
  const gate = safeAicm();
  if (!gate.ok) return { ...gate, exitCode: 1, spawned: false };
  let lock;
  try { lock = acquireLock(gate.aicmHome); } catch (e) {
    return { ok: false, status: e.status || 'refused', error: e.message, exitCode: 1, spawned: false };
  }
  const prevLease = process.env.AICM_MAINTENANCE_LEASE;
  const prevOwner = process.env.AICM_MAINTENANCE_OWNER;
  process.env.AICM_MAINTENANCE_LEASE = lock.lease;
  process.env.AICM_MAINTENANCE_OWNER = String(process.pid);
  try {
    const result = require('child_process').spawnSync(spec.executable, spec.args, {
      stdio: 'inherit',
      shell: false,
      env: { ...process.env },
    });
    const exitCode = Number.isInteger(result.status) ? result.status : 1;
    return { ok: exitCode === 0, status: exitCode === 0 ? 'ok' : 'error', exitCode, spawned: true };
  } finally {
    if (prevLease === undefined) delete process.env.AICM_MAINTENANCE_LEASE;
    else process.env.AICM_MAINTENANCE_LEASE = prevLease;
    if (prevOwner === undefined) delete process.env.AICM_MAINTENANCE_OWNER;
    else process.env.AICM_MAINTENANCE_OWNER = prevOwner;
    lock.release();
  }
}

function cliRunClean(argv) {
  const split = argv.indexOf('--');
  if (split < 0 || argv.slice(0, split).length) {
    return emit(false, 2, { ok: false, error: 'run-clean needs -- INTERPRETER ARGS' }, USAGE);
  }
  const rest = argv.slice(split + 1);
  if (rest.length < 2) return emit(false, 2, { ok: false, error: 'run-clean needs an interpreter and a script' }, USAGE);
  const result = runClean(rest[0], rest.slice(1));
  const code = Number.isInteger(result.exitCode) ? result.exitCode : 1;
  if (result.spawned) return code;
  if (wantsCleanJson(rest)) {
    console.log(asciiJson(cleanFailureDoc(result.error)));
    return code === 0 ? 1 : code;
  }
  console.error(`run-clean: ${result.error || 'cleanup failed'}`);
  return code === 0 ? 1 : code;
}

function main(argv) {
  const cmd = argv[0];
  if (!cmd || cmd === '-h' || cmd === '--help') {
    console.log(USAGE);
    return cmd ? 0 : 2;
  }
  if (cmd === 'archive-put') return cliArchivePut(argv.slice(1));
  if (cmd === 'archive-list') return cliArchiveList(argv.slice(1));
  if (cmd === 'archive-gc') return cliArchiveGc(argv.slice(1));
  if (cmd === 'restore') return cliRestore(argv.slice(1));
  if (cmd === 'history-add') return cliHistoryAdd(argv.slice(1));
  if (cmd === 'history') return cliHistory(argv.slice(1));
  if (cmd === 'run-clean') return cliRunClean(argv.slice(1));
  console.error(`unknown command: ${cmd}`);
  return 2;
}

if (require.main === module) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (e) { console.error(e.message || String(e)); process.exitCode = 1; }
}

module.exports = {
  USAGE, main, archivePut, archiveList, archiveGc, restore, historyAdd, historyList,
  pathAllowed, isProtectedPath, isSqliteFamily, isCodexNative, validateStored, tempLooksUsable,
  acquireLock, leaseValid, runClean, LOCK_NAME,
};
