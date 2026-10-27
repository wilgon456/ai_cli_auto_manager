#!/usr/bin/env node
// Opt-in maintenance of package-manager caches through a fixed allowlist of their own commands.
//
//   node optimize.js [--dry-run | --apply] [--tasks npm-verify,uv-prune,pnpm-prune] [--json]
//   node optimize.js --check ARG...            validate the arguments only (the dispatchers call this
//                                              before they claim AICM_HOME)
//   node optimize.js --refuse REASON ARG...    print the refusal for REASON in the requested format, exit 1
//
// The tasks run exactly one official command each, never anything else:
//   npm-verify  npm cache verify    checks the npm cache, garbage-collects unneeded entries
//   uv-prune    uv cache prune      removes unused entries from the uv cache
//   pnpm-prune  pnpm store prune    removes packages no project references from the pnpm store
// Pruned packages are downloaded again the next time a project needs them.
//
// Default and --dry-run: a preview. The tools are only looked up on PATH (absolute PATH entries only);
// none of them is started, nothing is written, no lock is taken. --apply (needs a claimed AICM_HOME)
// holds the maintenance lock (state/maintenance.lock, shared with cleanup, archive and restore) for
// the whole run and releases it on every exit. Each task is skipped while a process of that package
// manager runs (except this optimizer itself; package-manager ancestors also count) and also when the process table cannot be read.
// Each command runs with a time limit (AICM_OPTIMIZE_TIMEOUT seconds, default 900): on timeout its
// whole process group (Windows: process tree) is stopped. A failing task does not stop the others.
// Downloads are switched off for the children: Corepack network and prompts, npm offline, uv offline.
// On Windows a .cmd/.bat shim runs through %SystemRoot%\System32\cmd.exe with a quoted path and the
// fixed words above; a path with characters cmd.exe would interpret (" % ! ^ & | < > ( )) is refused.
// A .ps1 shim is never run.
//
// Exit 0: preview, or every selected task succeeded. Exit 1: refused, or a task failed, timed out,
// was skipped or is unavailable. Exit 2: invalid arguments (nothing was looked up or written).
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const TASKS = [
  { id: 'npm-verify', tool: 'npm', args: ['cache', 'verify'], busy: ['npm', 'npx'],
    effect: 'checks the npm cache and garbage-collects entries nothing needs; removed entries are downloaded again on demand' },
  { id: 'uv-prune', tool: 'uv', args: ['cache', 'prune'], busy: ['uv', 'uvx'],
    effect: 'removes unused entries from the uv cache; they are downloaded or rebuilt again on demand' },
  { id: 'pnpm-prune', tool: 'pnpm', args: ['store', 'prune'], busy: ['pnpm', 'pnpx'],
    effect: 'removes packages no project references from the pnpm store; projects may download them again' },
];
const TASK_IDS = TASKS.map((t) => t.id);

// Download and prompt guards for every child.
const GUARD_ENV = {
  COREPACK_ENABLE_NETWORK: '0',
  COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
  COREPACK_ENABLE_AUTO_PIN: '0',
  COREPACK_ENABLE_PROJECT_SPEC: '0',
  COREPACK_ENV_FILE: '0',
  // pnpm 11+ uses its own environment prefix; newer versions call bootstrap policy pmOnFail.
  pnpm_config_offline: 'true',
  pnpm_config_pm_on_fail: 'ignore',
  pnpm_config_manage_package_manager_versions: 'false',
  npm_config_manage_package_manager_versions: 'false',
  npm_config_offline: 'true',
  npm_config_update_notifier: 'false',
  npm_config_audit: 'false',
  npm_config_fund: 'false',
  npm_config_yes: 'false',
  UV_OFFLINE: '1',
  UV_NO_PROGRESS: '1',
  NO_UPDATE_NOTIFIER: '1',
};
const CMD_UNSAFE = /["%!^&|<>()\r\n\x00-\x1f]/;
const OUTPUT_TAIL = 2000;
const DEFAULT_TIMEOUT = 900;

function usageError(message) {
  const e = new Error(message);
  e.usage = true;
  return e;
}

function parseArgs(argv) {
  const opts = { apply: false, dryRun: false, json: false, tasks: TASK_IDS.slice(), help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply' || a === '-Apply') opts.apply = true;
    else if (a === '--dry-run' || a === '-DryRun') opts.dryRun = true;
    else if (a === '--json' || a === '-Json') opts.json = true;
    else if (a === '-h' || a === '--help') opts.help = true;
    else if (a === '--tasks' || a === '-Tasks' || a.startsWith('--tasks=')) {
      const value = a.startsWith('--tasks=') ? a.slice(8) : argv[++i];
      if (value === undefined || value.startsWith('-')) throw usageError('--tasks needs a comma-separated list: ' + TASK_IDS.join(','));
      const ids = value.split(',').map((s) => s.trim());
      if (!ids.length || ids.some((s) => !s)) throw usageError('--tasks has an empty entry');
      const unknown = ids.filter((s) => !TASK_IDS.includes(s));
      if (unknown.length) throw usageError(`unknown task: ${unknown.join(',')} (known: ${TASK_IDS.join(',')})`);
      if (new Set(ids).size !== ids.length) throw usageError('--tasks names a task twice');
      opts.tasks = ids;
    } else throw usageError(`unknown argument: ${a}`);
  }
  if (opts.apply && opts.dryRun) throw usageError('--apply and --dry-run cannot be combined');
  return opts;
}

function asciiJson(value) {
  return JSON.stringify(value).replace(/[^\x00-\x7f]/g, (ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
}

function doc(opts, status, tasks, errors, notes) {
  const count = (s) => tasks.filter((t) => t.status === s).length;
  return {
    schemaVersion: 1,
    command: 'optimize',
    mode: opts && opts.apply ? 'apply' : 'preview',
    dryRun: !(opts && opts.apply),
    status,
    tasks,
    summary: {
      selected: tasks.length,
      succeeded: count('ok'),
      failed: count('failed') + count('timeout'),
      skipped: count('busy') + count('skipped') + count('refused'),
      unavailable: count('unavailable'),
    },
    notes: notes || [],
    errors: errors || [],
  };
}

// ---------------------------------------------------------------------------
// Executable lookup (no execution)
// ---------------------------------------------------------------------------

const ON_WINDOWS = process.platform === 'win32';

// Windows environment names are case-insensitive (Path, PATH); a copied env object is not.
function envValue(env, name, win) {
  if (!win) return env[name];
  const key = Object.keys(env).find((k) => k.toUpperCase() === name.toUpperCase());
  return key === undefined ? undefined : env[key];
}

// win: Windows lookup rules (PATHEXT, ';'); a parameter so both are testable on any platform.
function resolveTool(name, env, win = ON_WINDOWS) {
  const sep = win ? ';' : ':';
  const dirs = String(envValue(env, 'PATH', win) || '').split(sep).filter(Boolean);
  const exts = win ? String(envValue(env, 'PATHEXT', win) || '.COM;.EXE;.BAT;.CMD').split(';').map((e) => e.trim().toLowerCase()).filter(Boolean) : [''];
  const isAbs = win ? path.win32.isAbsolute : path.posix.isAbsolute;
  const join = win ? path.win32.join : path.posix.join;
  for (const dir of dirs) {
    // A relative PATH entry would resolve against the current folder: never trusted.
    if (!isAbs(dir)) continue;
    for (const ext of exts) {
      const candidate = join(dir, name + ext);
      let st;
      try { st = fs.statSync(candidate); } catch { continue; }
      if (!st.isFile()) continue;
      if (!win && (st.mode & 0o111) === 0) continue;
      return candidate;
    }
  }
  return null;
}

// How a resolved tool is started: { file, args, verbatim } or { refused: reason }.
function launchSpec(exe, args, env, win = ON_WINDOWS) {
  if (!win) return { file: exe, args: args.slice(), verbatim: false };
  const ext = path.win32.extname(exe).toLowerCase();
  if (ext === '.exe' || ext === '.com') return { file: exe, args: args.slice(), verbatim: false };
  if (ext === '.cmd' || ext === '.bat') {
    if (CMD_UNSAFE.test(exe)) return { refused: 'the path contains characters cmd.exe would interpret; not run' };
    if (args.some((a) => !/^[a-z]+$/.test(a))) return { refused: 'unexpected argument; not run' };
    const systemRoot = envValue(env, 'SystemRoot', true) || 'C:\\Windows';
    if (CMD_UNSAFE.test(systemRoot) || !path.win32.isAbsolute(systemRoot)) return { refused: 'SystemRoot is not a plain absolute path; not run' };
    const cmd = path.win32.join(systemRoot, 'System32', 'cmd.exe');
    // /d: no AutoRun, /v:off: no delayed expansion, /s /c "..." keeps the inner quotes as written.
    return { file: cmd, args: ['/d', '/v:off', '/s', '/c', `""${exe}" ${args.join(' ')}"`], verbatim: true };
  }
  return { refused: `a ${ext || 'extensionless'} file is not started (only .exe, .com, .cmd and .bat)` };
}

// A Corepack shim may want to download its package manager first; the guards above make it fail instead.
function corepackHint(exe) {
  let real = exe;
  try { real = fs.realpathSync(exe); } catch { /* keep */ }
  if (/[\\/]corepack[\\/]/i.test(real)) return true;
  try {
    const st = fs.statSync(exe);
    if (st.size <= 4096) return /corepack/i.test(fs.readFileSync(exe, 'latin1'));
  } catch { /* unreadable: no hint */ }
  return false;
}

// ---------------------------------------------------------------------------
// Process table
// ---------------------------------------------------------------------------

// Throws when the table cannot be read; an empty table counts as unreadable too.
function listProcesses() {
  if (process.env.AICM_PROCESS_LIST) {
    const list = JSON.parse(fs.readFileSync(process.env.AICM_PROCESS_LIST, 'utf8'));
    if (!Array.isArray(list) || !list.length) throw new Error('empty process list');
    return list.map((p) => ({ pid: Number(p.pid), ppid: Number(p.ppid), cmd: String(p.cmd || ''), name: String(p.name || '') }));
  }
  if (process.platform === 'win32') {
    const systemRoot = process.env.SystemRoot || 'C:\\Windows';
    const ps = path.win32.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    const script = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); Get-CimInstance Win32_Process | ForEach-Object { [pscustomobject]@{ pid = [int]$_.ProcessId; ppid = [int]$_.ParentProcessId; name = [string]$_.Name; cmd = [string]$_.CommandLine } } | ConvertTo-Json -Compress';
    const r = spawnSync(ps, ['-NoProfile', '-NonInteractive', '-Command', script], { encoding: 'utf8', windowsHide: true, timeout: 60000, maxBuffer: 64 * 1024 * 1024 });
    if (r.error || r.status !== 0) throw new Error('Get-CimInstance Win32_Process failed');
    const list = JSON.parse(r.stdout || '[]');
    const arr = Array.isArray(list) ? list : [list];
    if (!arr.length) throw new Error('empty process list');
    return arr.map((p) => ({ pid: Number(p.pid), ppid: Number(p.ppid), cmd: String(p.cmd || ''), name: String(p.name || '') }));
  }
  const r = spawnSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, LC_ALL: 'C' } });
  if (r.error || r.status !== 0) throw new Error('ps failed');
  const out = [];
  for (const line of String(r.stdout || '').split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (m) out.push({ pid: +m[1], ppid: +m[2], cmd: m[3], name: path.basename(m[3].split(' ')[0] || '') });
  }
  if (!out.length) throw new Error('empty process list');
  return out;
}

// This process and the processes that started it (the dispatcher, a shell, a terminal).
function ownChain(list) {
  const byPid = new Map(list.map((p) => [p.pid, p]));
  const mine = new Set([process.pid]);
  let pid = process.ppid;
  for (let i = 0; i < 64 && pid > 1 && !mine.has(pid); i++) {
    mine.add(pid);
    const parent = byPid.get(pid);
    if (!parent) break;
    pid = parent.ppid;
  }
  return mine;
}

function stem(p) {
  const base = String(p || '').split(/[\\/]/).pop().toLowerCase();
  return base.replace(/\.(exe|cmd|bat|ps1|cjs|mjs|js)$/, '').replace(/-cli$/, '');
}

// The package manager a command line runs: its executable, or the script a node/bun interpreter runs.
function programNames(cmd, name) {
  const names = new Set();
  const tokens = [];
  for (const m of String(cmd).matchAll(/"([^"]*)"|(\S+)/g)) tokens.push(m[1] !== undefined ? m[1] : m[2]);
  const first = tokens[0] || name || '';
  names.add(stem(first));
  if (name) names.add(stem(name));
  if (/^(node|nodejs|bun)$/.test(stem(first))) {
    for (let i = 1; i < tokens.length; i++) {
      if (tokens[i].startsWith('-')) continue;
      names.add(stem(tokens[i]));
      break;
    }
  }
  // ps can print executable and interpreter script paths without quoting embedded spaces.
  // Recognize only known executable basenames at the start; keep normal token handling above.
  const raw = String(cmd || '');
  const executable = /^(?:"[^"\r\n]*[\\/](node|nodejs|bun|npm|npx|pnpm|pnpx|uv|uvx)(?:\.(?:exe|cmd|bat|ps1))?"|[^"\r\n]*?[\\/](node|nodejs|bun|npm|npx|pnpm|pnpx|uv|uvx)(?:\.(?:exe|cmd|bat|ps1))?)(?=\s|$)/i.exec(raw);
  if (executable) names.add((executable[1] || executable[2]).toLowerCase());
  if (['node', 'nodejs', 'bun'].some((n) => names.has(n))) {
    const script = /[\\/](npm-cli|npx-cli|pnpm|pnpx)(?:\.(?:js|cjs|mjs))(?=["\s]|$)/i.exec(raw);
    if (script) names.add(stem(script[1]));
  }
  return names;
}

// Pids of other processes of the task's package manager.
function busyPids(task, list) {
  const hits = [];
  for (const p of list) {
    if (p.pid === process.pid) continue;
    const names = programNames(p.cmd, p.name);
    if (task.busy.some((b) => names.has(b)) ||
        (!String(p.cmd || '').trim() && /^(node|nodejs|bun)$/.test(stem(p.name)) &&
         task.busy.some((b) => ['npm', 'npx', 'pnpm', 'pnpx'].includes(b)))) hits.push(p.pid);
  }
  return hits;
}

// ---------------------------------------------------------------------------
// Running one command
// ---------------------------------------------------------------------------

function timeoutSeconds() {
  const v = String(process.env.AICM_OPTIMIZE_TIMEOUT || '');
  if (/^[1-9][0-9]{0,4}$/.test(v)) return Math.min(Number(v), 7200);
  return DEFAULT_TIMEOUT;
}

function tail(text) {
  const t = String(text || '').replace(/\r/g, '');
  return t.length > OUTPUT_TAIL ? t.slice(t.length - OUTPUT_TAIL) : t;
}

let running = null;

function stopTree(child) {
  if (process.platform === 'win32') {
    const systemRoot = process.env.SystemRoot || 'C:\\Windows';
    spawnSync(path.win32.join(systemRoot, 'System32', 'taskkill.exe'), ['/T', '/F', '/PID', String(child.pid)], { windowsHide: true, timeout: 30000 });
    return;
  }
  try { process.kill(-child.pid, 'SIGTERM'); } catch { /* gone */ }
  // A command that ignores TERM gets KILL; the child handle keeps this process waiting for it.
  const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* gone */ } }, 2000);
  timer.unref();
  child.once('close', () => clearTimeout(timer));
}

function runCommand(spec, env, seconds) {
  return new Promise((resolve) => {
    const started = Date.now();
    let out = '';
    let timedOut = false;
    let child;
    try {
      child = spawn(spec.file, spec.args, {
        env, shell: false, windowsHide: true, windowsVerbatimArguments: !!spec.verbatim,
        detached: process.platform !== 'win32', stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (e) {
      resolve({ exitCode: null, signal: null, timedOut: false, error: e.message, output: '', durationMs: 0 });
      return;
    }
    running = child;
    const keep = (d) => { out = tail(out + d.toString('utf8')); };
    child.stdout.on('data', keep);
    child.stderr.on('data', keep);
    const timer = setTimeout(() => { timedOut = true; stopTree(child); }, seconds * 1000);
    let spawnError = null;
    child.on('error', (e) => { spawnError = e.message; });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      running = null;
      // The command is done; stop anything it left in its group.
      if (process.platform !== 'win32') { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* none left */ } }
      resolve({ exitCode: Number.isInteger(code) ? code : null, signal: signal || null, timedOut, error: spawnError, output: out, durationMs: Date.now() - started });
    });
  });
}

// ---------------------------------------------------------------------------
// Plan and apply
// ---------------------------------------------------------------------------

function planTask(task, env) {
  const row = {
    id: task.id,
    tool: task.tool,
    command: [task.tool].concat(task.args).join(' '),
    argv: task.args.slice(),
    effect: task.effect,
    executable: null,
    status: 'would-run',
    reason: '',
    exitCode: null,
    durationMs: null,
    output: '',
  };
  const exe = resolveTool(task.tool, env);
  if (!exe) { row.status = 'unavailable'; row.reason = `${task.tool} not found on PATH`; return { row }; }
  row.executable = exe;
  const spec = launchSpec(exe, task.args, env);
  if (spec.refused) { row.status = 'refused'; row.reason = spec.refused; return { row }; }
  if (corepackHint(exe)) row.reason = 'Corepack shim: runs offline, so a version that is not downloaded yet fails instead of downloading';
  return { row, spec };
}

function childEnv() {
  const guarded = new Set(Object.keys(GUARD_ENV).map((k) => k.toLowerCase()));
  const env = {};
  for (const [k, value] of Object.entries(process.env)) {
    if (!guarded.has(k.toLowerCase()) && !k.toUpperCase().startsWith('AICM_MAINTENANCE_')) env[k] = value;
  }
  Object.assign(env, GUARD_ENV);
  return env;
}

function homeClaimed(aicmHome) {
  try {
    const st = fs.lstatSync(path.join(aicmHome, '.aicm-home'));
    return st.isFile() && !st.isSymbolicLink();
  } catch { return false; }
}

async function apply(opts, plans, env, say) {
  const maintenance = require('./maintenance.js');
  const common = require('./node-common');
  const aicmHome = path.resolve(common.paths().aicmHome);
  if (!homeClaimed(aicmHome)) {
    return { status: 'refused', errors: ['AICM_HOME is not claimed by this tool; run it through aicm optimize --apply'] };
  }
  let lock;
  try { lock = maintenance.acquireLock(aicmHome); } catch (e) {
    const why = e.status === 'locked' ? 'another cleanup, archive, restore or optimize run holds the maintenance lock' : (e.message || 'maintenance lock refused');
    return { status: 'refused', errors: [why] };
  }
  const release = () => { try { lock.release(); } catch { /* released */ } };
  // Interrupted: the running command (and everything in its group) is stopped first; the lock is
  // released only once it is gone, so no cache command keeps writing after the lease ends. One that
  // cannot be stopped within 15 s leaves the lock to be reclaimed after this process has exited.
  let cancelling = false;
  const onSignal = (sig) => {
    const code = sig === 'SIGINT' ? 130 : 143;
    if (cancelling) return;
    cancelling = true;
    const child = running;
    if (!child) { release(); process.exit(code); }
    child.once('close', () => {
      if (process.platform !== 'win32') { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* none left */ } }
      release();
      process.exit(code);
    });
    stopTree(child);
    setTimeout(() => {
      process.stderr.write(`aicm optimize: pid ${child.pid} did not stop; the maintenance lock is reclaimed once this run has exited\n`);
      process.exit(code);
    }, 15000).unref();
  };
  const onInt = () => onSignal('SIGINT');
  const onTerm = () => onSignal('SIGTERM');
  process.on('SIGINT', onInt);
  process.on('SIGTERM', onTerm);
  try {
    const seconds = timeoutSeconds();
    for (const plan of plans) {
      const row = plan.row;
      if (!plan.spec || cancelling) continue;
      let list;
      try { list = listProcesses(); } catch (e) {
        row.status = 'skipped'; row.reason = `process table unavailable (${e.message}): cannot rule out a running ${row.tool}`;
        continue;
      }
      const busy = busyPids({ busy: TASKS.find((t) => t.id === row.id).busy }, list);
      if (busy.length) { row.status = 'busy'; row.reason = `${row.tool} may be active (pid ${busy.slice(0, 5).join(', ')}); skipped`; continue; }
      say(`running: ${row.command} (${row.executable})`);
      const r = await runCommand(plan.spec, env, seconds);
      row.exitCode = r.exitCode;
      row.durationMs = r.durationMs;
      row.output = r.output;
      if (r.timedOut) { row.status = 'timeout'; row.reason = `stopped after ${seconds}s (AICM_OPTIMIZE_TIMEOUT)`; }
      else if (r.error && r.exitCode === null) { row.status = 'failed'; row.reason = `could not start: ${r.error}`; }
      else if (r.signal) { row.status = 'failed'; row.reason = `ended by signal ${r.signal}`; }
      else if (r.exitCode === 0) { row.status = 'ok'; }
      else { row.status = 'failed'; row.reason = `exit code ${r.exitCode}`; }
    }
  } finally {
    process.removeListener('SIGINT', onInt);
    process.removeListener('SIGTERM', onTerm);
    release();
  }
  const all = plans.map((p) => p.row);
  const ok = all.every((t) => t.status === 'ok');
  return { status: ok ? 'ok' : (all.some((t) => t.status === 'ok') ? 'partial' : 'failed'), errors: [] };
}

function printHuman(d) {
  console.log(`optimize ${d.mode === 'apply' ? '(apply)' : '(preview: nothing is run; add --apply to run)'}`);
  for (const t of d.tasks) {
    const where = t.executable ? `  ${t.executable}` : '';
    const extra = t.reason ? `  - ${t.reason}` : '';
    console.log(`${t.id.padEnd(11)} ${t.status.padEnd(11)} ${t.command}${where}${extra}`);
    if (d.mode === 'apply' && t.status !== 'ok' && t.output) {
      const last = t.output.trim().split('\n').slice(-3).join(' | ');
      if (last) console.log(`${''.padEnd(11)} output: ${last}`);
    }
  }
  if (d.mode === 'preview') for (const t of d.tasks) if (t.status === 'would-run') console.log(`${''.padEnd(11)} ${t.id}: ${t.effect}`);
  for (const e of d.errors) console.log(`problem: ${e}`);
  for (const n of d.notes) console.log(`note: ${n}`);
  const s = d.summary;
  console.log(`selected ${s.selected}, succeeded ${s.succeeded}, failed ${s.failed}, skipped ${s.skipped}, unavailable ${s.unavailable}`);
}

async function main(argv) {
  const wantsJson = argv.some((a) => a === '--json' || a === '-Json');
  const emit = (d, code) => {
    if (wantsJson) process.stdout.write(asciiJson(d) + '\n'); else printHuman(d);
    return code;
  };
  if (argv[0] === '--refuse') {
    const reason = String(argv[1] || 'refused').replace(/[\0\r\n]/g, ' ').slice(0, 400);
    let opts = null;
    try { opts = parseArgs(argv.slice(2)); } catch { opts = { apply: true }; }
    if (!wantsJson) { console.error(`aicm optimize: ${reason}`); return 1; }
    return emit(doc(opts, 'refused', [], [reason]), 1);
  }
  const check = argv[0] === '--check';
  let opts;
  try { opts = parseArgs(check ? argv.slice(1) : argv); } catch (e) {
    if (wantsJson) process.stdout.write(asciiJson(doc(null, 'error', [], [e.message])) + '\n');
    else console.error(`aicm optimize: ${e.message}`);
    return 2;
  }
  if (opts.help) {
    if (!check) console.log(`usage: aicm optimize [--dry-run | --apply] [--tasks ${TASK_IDS.join(',')}] [--json]`);
    return 0;
  }
  if (check) return 0;
  const env = childEnv();
  const plans = TASKS.filter((t) => opts.tasks.includes(t.id)).map((t) => planTask(t, env));
  const notes = ['logical cache entries removed here are downloaded or rebuilt again when a project needs them'];
  if (!opts.apply) {
    return emit(doc(opts, 'preview', plans.map((p) => p.row), [], notes), 0);
  }
  const say = (line) => { if (wantsJson) process.stderr.write(line + '\n'); else console.log(line); };
  const result = await apply(opts, plans, env, say);
  const rows = plans.map((p) => p.row);
  if (result.status === 'refused') for (const r of rows) if (r.status === 'would-run') { r.status = 'skipped'; r.reason = 'not run: ' + result.errors[0]; }
  return emit(doc(opts, result.status, rows, result.errors, notes), result.status === 'ok' ? 0 : 1);
}

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => { process.exitCode = code; }, (e) => {
    console.error(`aicm optimize: ${e && e.message ? e.message : e}`);
    process.exitCode = 1;
  });
}

module.exports = { TASKS, TASK_IDS, GUARD_ENV, parseArgs, resolveTool, launchSpec, programNames, busyPids, ownChain, main };
