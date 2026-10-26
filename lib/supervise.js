#!/usr/bin/env node
// A separate guardian owns the CLI's session/process group. IPC EOF still reaches it if the
// launcher is SIGKILLed. Never share the caller's terminal group or kill by command name.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { fork, spawn, spawnSync } = require('child_process');
const { paths } = require('./node-common');

function birth(pid) {
  const r = spawnSync('ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } });
  return r.status === 0 ? r.stdout.trim().replace(/\s+/g, ' ') : '';
}
function alive(pid, started) { return Boolean(started && birth(pid) === started); }
function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); return true; } catch (e) { if (e.code === 'ESRCH') return false; throw e; }
}
function groupMembers(pgid) {
  const r = spawnSync('ps', ['-axo', 'pid=,pgid=,uid=,stat='], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('Cannot verify contained process group');
  return r.stdout.split('\n').map((line) => /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)/.exec(line))
    .filter((m) => m && +m[2] === pgid && !m[4].startsWith('Z')).map((m) => ({ pid: +m[1], uid: +m[3] }));
}
async function stopGroup(pid, grace = 1000, verify) {
  const members = groupMembers(pid);
  if (!members.length) return; // Darwin can report EPERM instead of ESRCH for an extinct group.
  if (members.some((p) => p.uid !== process.getuid())) throw new Error('Contained group ownership changed');
  if (!signalGroup(pid, 'SIGTERM')) return;
  await new Promise((r) => setTimeout(r, grace));
  const remaining = groupMembers(pid);
  if (remaining.length && remaining.every((p) => p.uid === process.getuid()) && (!verify || await verify())) signalGroup(pid, 'SIGKILL');
}
async function guardian() {
  let child, stopping = false, record, file;
  const done = async (code, reason) => {
    if (stopping) return;
    stopping = true;
    clearInterval(poll);
    clearTimeout(timer);
    if (child && child.pid) {
      try { await stopGroup(child.pid); } catch (e) { console.error(`containment: ${e.message}`); code = 125; }
    }
    if (record) {
      record.endedAt = new Date().toISOString(); record.reason = reason;
      try { fs.writeFileSync(file, JSON.stringify(record), { mode: 0o600 }); } catch { }
    }
    if (process.connected) process.send({ code }, () => process.exit(code));
    else process.exit(code);
  };
  let poll, timer;
  process.on('disconnect', () => done(125, 'launcher exited'));
  process.on('SIGTERM', () => done(143, 'guardian terminated'));
  process.on('SIGINT', () => done(130, 'interrupted'));
  process.once('message', (request) => {
    const session = crypto.randomUUID();
    const { aicmHome } = paths();
    const dir = path.join(aicmHome, 'state', 'sessions');
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    file = path.join(dir, session + '.json');
    child = spawn(request.command[0], request.command.slice(1), {
      detached: true, stdio: 'inherit', env: { ...process.env, AI_CLI_MANAGER_SESSION: session, AICM_CONTAINED: '1' },
    });
    child.once('error', (e) => { console.error(`launch: ${e.message}`); done(127, 'launch failed'); });
    child.once('exit', (code, signal) => done(code === null ? (signal === 'SIGINT' ? 130 : 143) : code, 'command exited'));
    if (child.pid) {
      record = { session, pid: child.pid, pgid: child.pid, created: birth(child.pid), ownerPid: request.ownerPid,
        ownerCreated: request.ownerCreated, guardianPid: process.pid, guardianCreated: birth(process.pid), startedAt: new Date().toISOString(), platform: process.platform };
      fs.writeFileSync(file, JSON.stringify(record), { mode: 0o600 });
    }
    poll = setInterval(() => { if (!alive(request.ownerPid, request.ownerCreated)) done(125, 'parent exited'); }, 500);
    if (request.timeout) timer = setTimeout(() => { console.error(`TIMEOUT after ${request.timeout}s`); done(124, 'timeout'); }, request.timeout * 1000);
    process.on('message', (m) => { if (m.stop) done(m.code || 143, 'interrupted'); });
  });
}
async function main(argv) {
  if (process.platform === 'win32') throw new Error('Use the PowerShell Job Object launcher on Windows');
  let timeout = 0;
  if (argv[0] === '--timeout') { timeout = Number(argv[1]); argv = argv.slice(2); }
  if (argv[0] !== '--' || argv.length < 2 || !Number.isFinite(timeout) || timeout < 0) {
    console.error('usage: supervise.js [--timeout seconds] -- command [args...]'); return 2;
  }
  const ownerPid = process.ppid, ownerCreated = birth(ownerPid);
  if (!ownerCreated) throw new Error('Cannot identify launcher parent');
  const guard = fork(__filename, ['--guardian'], { detached: true, stdio: ['inherit', 'inherit', 'inherit', 'ipc'] });
  let result = 125;
  guard.on('message', (m) => { result = m.code; });
  for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
    process.on(sig, () => { if (guard.connected) guard.send({ stop: true, code }); });
  }
  guard.send({ command: argv.slice(1), timeout, ownerPid, ownerCreated });
  return new Promise((resolve) => guard.on('exit', () => resolve(result)));
}
if (require.main === module) {
  (process.argv[2] === '--guardian' ? guardian() : main(process.argv.slice(2)).then((code) => { process.exitCode = code; }))
    .catch((e) => { console.error(e.message); process.exitCode = 1; });
}
module.exports = { birth, alive, stopGroup };
