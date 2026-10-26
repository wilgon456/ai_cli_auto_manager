#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const common = require('./node-common');
const files = require('./maintenance-files');
const processes = require('./maintenance-processes');
const { parse } = require('./npm-guard');
function compareVersions(a, b) {
  const x = parse(a.split('+')[0]), y = parse(b.split('+')[0]);
  if (!x || !y) return 0;
  for (let i = 0; i < 3; i++) { if (x.nums[i] !== y.nums[i]) return x.nums[i] - y.nums[i]; }
  return x.pre && !y.pre ? -1 : 0;
}

function versionWarnings(inventory, floors = { claude: '2.1.283' }) {
  const warnings = [];
  for (const cli of inventory?.clis || []) {
    const id = cli.id || cli.Id, version = cli.version || cli.Version, floor = floors[id];
    if (floor && /^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/.test(version || '') && compareVersions(version, floor) < 0) warnings.push({ action: 'alert', reason: `CLI version below configured floor ${floor}; run aicm update --targets ${id}`, cli: id, version, floor });
  }
  return warnings;
}
function options(argv) {
  const out = { apply: false, json: false, files: true, processes: true };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--apply': out.apply = true; break;
      case '--dry-run': out.dryRun = true; break;
      case '--json': out.json = true; break;
      case '--config': if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error('--config needs a path'); out.config = argv[++i]; break;
      case '--processes-only': out.files = false; break;
      case '--files-only': out.processes = false; break;
      case '--help': out.help = true; break;
      default: throw new Error(`Unknown maintenance argument: ${argv[i]}`);
    }
  }
  if (out.dryRun) out.apply = false;
  return out;
}
function dailySummary(logFile, day) {
  const counts = {};
  for (const line of fs.readFileSync(logFile, 'utf8').split('\n').filter(Boolean)) {
    try { const r = JSON.parse(line); counts[r.action] = (counts[r.action] || 0) + 1; } catch { }
  }
  return `${day}: ` + Object.entries(counts).map(([a, n]) => `${n} ${a}`).join(', ');
}
async function run(context, opts, adapters = {}) {
  const now = opts.now || Date.now(), day = new Date(now).toISOString().slice(0, 10);
  if (!files.noLinks(context.aicmHome)) throw new Error('Manager home has a linked ancestor');
  for (const dir of ['state', 'logs']) {
    const p = path.join(context.aicmHome, dir);
    if (!files.noLinks(p)) throw new Error('Maintenance state/log path is linked');
    fs.mkdirSync(p, { recursive: true, mode: 0o700 });
  }
  const lock = path.join(context.aicmHome, 'state', 'maintenance.lock');
  let fd;
  try { fd = fs.openSync(lock, 'wx', 0o600); } catch (e) { if (e.code === 'EEXIST') throw new Error('Maintenance already running or stale lock; verify the recorded PID before removing state/maintenance.lock'); throw e; }
  fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, startedAt: new Date(now).toISOString() }));
  const actions = [], logFile = path.join(context.aicmHome, 'logs', `maintenance-${day}.jsonl`);
  if (!files.noLinks(logFile)) { fs.closeSync(fd); fs.unlinkSync(lock); throw new Error('Maintenance log is linked'); }
  const log = (a) => {
    const entry = { timestamp: new Date(now).toISOString(), dryRun: !opts.apply, ...a };
    fs.appendFileSync(logFile, JSON.stringify(entry) + '\n', { mode: 0o600 }); actions.push(entry);
  };
  try {
    log({ action: 'run', reason: opts.apply ? 'explicit apply' : 'default dry-run' });
    const previous = common.readState(context.aicmHome, 'last-maintenance');
    const last = previous && Date.parse(previous.fileClockAt || previous.finishedAt);
    const clockSafe = process.env.AICM_CLOCK_CHECK === '0' || !Number.isFinite(last) || (now >= last && now - last <= 400 * 86400000);
    if (opts.files) {
      if (!clockSafe) log({ action: 'skip', reason: 'clock moved backwards or jumped more than 400 days; file maintenance withheld' });
      else files.cleanup(context, files.readRules(context, opts.config), opts, log);
    }
    if (opts.processes) {
      try { await processes.scan(context, opts, log, adapters); }
      catch (e) { log({ action: 'error', reason: e.message }); }
    }
    const inventory = common.readState(context.aicmHome, 'inventory');
    let floors = { claude: '2.1.283' };
    const floorFile = path.join(context.aicmHome, 'version-floors.json');
    if (fs.existsSync(floorFile)) floors = { ...floors, ...JSON.parse(fs.readFileSync(floorFile, 'utf8')) };
    for (const a of versionWarnings(inventory, floors)) log(a);
    const summary = dailySummary(logFile, day);
    const result = { fileClockAt: new Date(clockSafe || !Number.isFinite(last) ? now : last).toISOString(), finishedAt: new Date(now).toISOString(), ok: !actions.some((a) => a.action === 'error'), dryRun: !opts.apply, summary, actions };
    common.writeState(context.aicmHome, 'last-maintenance', result);
    // A short daily file is updated from the action log, so repeated hourly runs accumulate.
    const summaryFile = path.join(context.aicmHome, 'logs', `maintenance-${day}.txt`);
    if (!files.noLinks(summaryFile)) throw new Error('Maintenance summary is linked');
    fs.writeFileSync(summaryFile, summary + '\n', { mode: 0o600 });
    return result;
  } catch (e) {
    log({ action: 'error', reason: e.message });
    const previous = common.readState(context.aicmHome, 'last-maintenance');
    common.writeState(context.aicmHome, 'last-maintenance', { fileClockAt: previous?.fileClockAt || previous?.finishedAt, finishedAt: new Date(now).toISOString(), ok: false, dryRun: !opts.apply, actions });
    throw e;
  } finally { fs.closeSync(fd); fs.unlinkSync(lock); }
}
async function main(argv) {
  let opts;
  try { opts = options(argv); } catch (e) { console.error(e.message); return 2; }
  if (opts.help) { console.log('usage: aicm maintenance [--dry-run|--apply] [--json] [--config path] [--files-only|--processes-only]'); return 0; }
  const context = { ...common.paths(), temp: os.tmpdir() };
  try {
    const result = await run(context, opts);
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else {
      for (const a of result.actions.filter((a) => a.action !== 'run')) console.log(`${a.action}: ${a.path || a.cli || (a.pid ? `pid ${a.pid} ${a.name}` : '')} (${a.reason})`);
      console.log(result.summary);
      const attention = result.actions.filter((a) => a.action === 'alert' || a.action === 'error').map((a) => `${a.cli || a.name || 'maintenance'}${a.pid ? ` (pid ${a.pid}, started ${a.created})` : ''}: ${a.reason}`);
      for (const a of common.newSince(context.aicmHome, 'maintenance-attention', attention)) console.log(`attention: ${a}`);
    }
    return result.ok ? 0 : 1;
  } catch (e) { console.error(`maintenance: ${e.message}`); return 1; }
}
if (require.main === module) main(process.argv.slice(2)).then((code) => { process.exitCode = code; }).catch((e) => { console.error(e.message); process.exitCode = 1; });
module.exports = { run, main, options, versionWarnings, dailySummary };
