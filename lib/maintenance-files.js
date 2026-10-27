'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const DAY = 86400000;
const PROTECTED = /(^|[\\/])(memory|credentials?|secrets?)([\\/]|$)|(^|[\\/])(MEMORY\.md|CLAUDE\.md|AGENTS\.md|GEMINI\.md|auth\.json|\.credentials\.json|settings\.json|config\.(toml|json)|\.npmrc|\.netrc|.*\.env(?:\..*)?|.*\.(pem|key|sqlite\d*|db)(?:-(?:wal|shm|journal))?|id_(?:rsa|ed25519).*)$/i;
function under(p, root) { const rel = path.relative(root, p); return Boolean(rel && rel !== '..' && !rel.startsWith('..' + path.sep) && !path.isAbsolute(rel)); }
function noLinks(p) {
  for (let cur = path.resolve(p); ; cur = path.dirname(cur)) {
    try { if (fs.lstatSync(cur).isSymbolicLink()) return false; }
    catch (e) { if (e.code !== 'ENOENT') return false; }
    if (path.dirname(cur) === cur) return true;
  }
}
function glob(pattern, text) {
  const source = pattern.split(/(\*\*|\*|\?)/).map((x) => x === '**' ? '.*' : x === '*' ? '[^/]*' : x === '?' ? '[^/]' : x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('');
  return new RegExp('^' + source + '$', 'i').test(text.replace(/\\/g, '/'));
}
function parseRules(text, context) {
  const rules = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const cols = line.split('|').map((x) => x.trim());
    const [id, raw, age, exclude = ''] = cols;
    if (cols.length !== 4 || !/^[a-z][a-z0-9-]*$/.test(id) || !/^\d+$/.test(age) || +age < 2) throw new Error(`Invalid maintenance rule: ${id || 'unnamed'} (age must be >=2 days)`);
    const expanded = raw.replace(/^~(?=[/\\]|$)/, context.home).replaceAll('{aicm}', context.aicmHome).replaceAll('{temp}', context.temp || os.tmpdir());
    if (!path.isAbsolute(expanded)) throw new Error(`Rule ${id} needs an absolute path`);
    const root = path.resolve(expanded);
    const safeTemp = context.temp && !under(context.home, context.temp) && context.temp !== context.home && path.parse(context.temp).root !== context.temp;
    if (!under(root, context.home) && !(safeTemp && under(root, context.temp))) throw new Error(`Unsafe maintenance path in ${id}`);
    for (const reserved of ['quarantine', 'state', 'logs', 'app', 'hooks', 'archive']) {
      const p = path.join(context.aicmHome, reserved);
      if (root === p || under(root, p) || under(p, root)) throw new Error(`Rule ${id} overlaps manager data`);
    }
    if (root === context.aicmHome || PROTECTED.test(root)) throw new Error(`Unsafe maintenance path in ${id}`);
    rules.push({ id, root, days: +age, excludes: exclude.split(',').map((x) => x.trim()).filter(Boolean) });
  }
  return rules;
}
function readRules(context, config) {
  const map = new Map();
  for (const file of [config || path.join(__dirname, '..', 'rules', 'maintenance.conf'), path.join(context.aicmHome, 'maintenance.local.conf')]) {
    if (!fs.existsSync(file)) { if (file === config) throw new Error('Maintenance config not found'); continue; }
    for (const r of parseRules(fs.readFileSync(file, 'utf8'), context)) map.set(r.id, r);
  }
  return [...map.values()];
}
function idle(file) {
  if (process.platform === 'win32') return true; // the mutation acquires an exclusive native handle
  const r = spawnSync('lsof', ['-t', '--', file], { encoding: 'utf8', timeout: 10000 });
  return !r.error && r.status === 1 && !r.stdout.trim() && !r.stderr.trim();
}
function mutate(operation, source, destination, expected) {
  if (!noLinks(source) || !idle(source)) return false;
  if (expected) { const current = fs.lstatSync(source); if (current.ino !== expected.ino || current.mtimeMs !== expected.mtimeMs || current.size !== expected.size) return false; }
  if (process.platform === 'win32') {
    return spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'maintenance-files.ps1'), '-Operation', operation, '-Source', source, ...(destination ? ['-Destination', destination] : [])], { windowsHide: true, timeout: 30000 }).status === 0;
  }
  // Hold a descriptor and recheck identity immediately before the rename/unlink. Links are never followed.
  let fd;
  try {
    fd = fs.openSync(source, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const s = fs.fstatSync(fd), current = fs.lstatSync(source);
    if (!s.isFile() || s.nlink !== 1 || (s.mode & 0o222) === 0 || s.ino !== current.ino || s.dev !== current.dev || !noLinks(source)) return false;
    if (destination) { if (!noLinks(path.dirname(destination)) || fs.existsSync(destination)) return false; fs.renameSync(source, destination); }
    else fs.unlinkSync(source);
    return true;
  } catch { return false; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
function* candidates(rule, now, dir = rule.root) {
  if (!noLinks(dir)) return;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const file = path.join(dir, e.name), rel = path.relative(rule.root, file).replace(/\\/g, '/');
    if (PROTECTED.test(file) || rule.excludes.some((x) => glob(x, rel) || glob(x, e.name)) || e.isSymbolicLink()) continue;
    if (e.isDirectory()) { yield* candidates(rule, now, file); continue; }
    if (!e.isFile()) continue;
    const s = fs.lstatSync(file);
    if (s.nlink === 1 && (s.mode & 0o222) !== 0 && now - Math.max(s.mtimeMs, s.atimeMs, s.birthtimeMs) >= rule.days * DAY) yield { file, stat: s };
  }
}
function cleanup(context, rules, opts, log) {
  const now = opts.now || Date.now(), quarantine = path.join(context.aicmHome, 'quarantine');
  if (!noLinks(context.aicmHome)) throw new Error('Manager home has a linked ancestor');
  if (!noLinks(quarantine)) throw new Error('Quarantine has a linked ancestor');
  for (const rule of rules) {
    if (!noLinks(rule.root)) { log({ action: 'skip', reason: 'linked cleanup root', rule: rule.id }); continue; }
    for (const { file, stat } of candidates(rule, now)) {
      if (!idle(file)) { log({ action: 'skip', reason: 'file open or lock check unavailable', path: file, rule: rule.id }); continue; }
      const action = { action: opts.apply ? 'quarantine' : 'would-quarantine', reason: `unused for at least ${rule.days} days`, path: file, rule: rule.id, bytes: stat.size };
      if (opts.apply) {
        const dir = path.join(quarantine, crypto.randomUUID()); fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
        const payload = path.join(dir, 'payload');
        // Write recovery metadata BEFORE moving anything. Crash recovery always keeps this metadata.
        fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({ format: 1, source: file, quarantinedAt: new Date(now).toISOString(), bytes: stat.size }), { mode: 0o600 });
        if (!mutate('move', file, payload, stat)) {
          action.action = 'skip'; action.reason = 'locked, changed, linked or cross-volume file';
          fs.unlinkSync(path.join(dir, 'manifest.json')); fs.rmdirSync(dir);
        }
        else action.quarantine = dir;
      }
      log(action);
    }
  }
  if (!fs.existsSync(quarantine)) return;
  for (const e of fs.readdirSync(quarantine, { withFileTypes: true })) {
    if (!e.isDirectory() || !/^[0-9a-f-]{36}$/.test(e.name)) continue;
    const dir = path.join(quarantine, e.name), payload = path.join(dir, 'payload');
    try {
      if (!noLinks(dir) || !noLinks(payload) || !noLinks(path.join(dir, 'manifest.json'))) continue;
      const names = fs.readdirSync(dir);
      if (names.some((x) => !['manifest.json', 'payload'].includes(x))) continue;
      const m = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
      const time = Date.parse(m.quarantinedAt);
      if (m.format !== 1 || !path.isAbsolute(m.source) || !Number.isFinite(time) || now - time < 7 * DAY || !fs.lstatSync(payload).isFile()) continue;
      const action = { action: opts.apply ? 'purge' : 'would-purge', reason: 'quarantined for at least 7 days', path: payload };
      if (opts.apply) {
        if (mutate('purge', payload)) { fs.unlinkSync(path.join(dir, 'manifest.json')); fs.rmdirSync(dir); }
        else { action.action = 'skip'; action.reason = 'quarantined file open or lock check unavailable'; }
      }
      log(action);
    } catch (e) { if (e.code !== 'ENOENT') log({ action: 'skip', reason: 'unreadable quarantine entry', path: dir }); }
  }
}
module.exports = { parseRules, readRules, cleanup, candidates, noLinks, under, glob, PROTECTED };
