'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { stopGroup } = require('./supervise');
const PROTECTED = /\b(paseo|sshd?|mosh|systemd|launchd|services\.exe|wininit|winlogon|csrss|lsass)\b|app-server|language-server|\bsandbox\b/i;
const AGENT = /\b(claude|codex|opencode|gemini|qwen|grok|kimi|cursor-agent|copilot|auggie|droid)\b/i;
const RUNTIME = /^(node|nodejs|bun|pythonw?[\d.]*|py)(\.exe)?$/i;
function ps(command, args) {
  const r = spawnSync(command, args, { encoding: 'utf8', windowsHide: true, timeout: 30000, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, LC_ALL: 'C' } });
  if (r.error || r.status !== 0) throw new Error(`Process inspection failed: ${command}`);
  return r.stdout;
}
function snapshot() {
  const now = Date.now();
  if (process.platform === 'win32') {
    // Never log environment blocks or command lines. Missing owner/elevation => protected.
    const code = `
Add-Type -Path '${path.join(__dirname, 'aicm-process-token.cs').replaceAll("'", "''")}'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ports = @{}
Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object { $ports[[int]$_.OwningProcess] = $true }
$rows = @(Get-CimInstance Win32_Process | ForEach-Object {
  $owner = ''; try { $owner = (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch { }
  [pscustomobject]@{ pid=[int]$_.ProcessId; ppid=[int]$_.ParentProcessId; name=$_.Name; cmd=[string]$_.CommandLine;
    created=$(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { '' }); uid=$owner; elevated=[Aicm.ProcessToken]::Elevated([int]$_.ProcessId); listening=$ports.ContainsKey([int]$_.ProcessId) }
})
@{ uid=$sid; procs=$rows } | ConvertTo-Json -Compress -Depth 4`;
    const out = JSON.parse(ps('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', code]));
    for (const p of out.procs) p.ageSec = (now - Date.parse(p.created)) / 1000;
    return out;
  }
  const text = ps('ps', ['-axo', 'pid=,ppid=,pgid=,uid=,lstart=,comm=']);
  const procs = [];
  for (const line of text.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const created = m[5].replace(/\s+/g, ' ');
    procs.push({ pid: +m[1], ppid: +m[2], pgid: +m[3], uid: +m[4], created, ageSec: (now - Date.parse(created)) / 1000, name: path.basename(m[6]), cmd: m[6], elevated: +m[4] === 0 });
  }
  const uid = process.getuid();
  // Per-user listing keeps a remote/daemon ancestor's command recognizable, without collecting env.
  const commands = ps('ps', ['-axo', 'pid=,command=']);
  for (const line of commands.split('\n')) {
    const m = /^\s*(\d+)\s+(.*)$/.exec(line); if (!m) continue;
    const p = procs.find((p) => p.pid === +m[1]); if (p) p.cmd = m[2];
  }
  const r = spawnSync('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-Fpu'], { encoding: 'utf8', timeout: 30000 });
  const listening = new Set();
  if (!r.error && (r.status === 0 || (r.status === 1 && !r.stderr.trim()))) {
    for (const line of r.stdout.split('\n')) if (/^p\d+$/.test(line)) listening.add(+line.slice(1));
  }
  for (const p of procs) {
    p.listening = listening.has(p.pid);
    if (p.uid !== uid) continue;
    try {
      let env;
      if (process.platform === 'linux') env = fs.readFileSync(`/proc/${p.pid}/environ`, 'utf8');
      else env = ps('ps', ['eww', '-p', String(p.pid), '-o', 'command=']);
      const tag = /(?:^|[\0\s])AI_CLI_MANAGER_SESSION=([a-f0-9-]{36})(?=[\0\s]|$)/i.exec(env);
      if (tag) p.session = tag[1];
    } catch { /* permission/race: ownership stays unknown */ }
  }
  return { uid, procs };
}
function sessions(aicmHome) {
  const dir = path.join(aicmHome, 'state', 'sessions');
  const records = new Map();
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!/^[a-f0-9-]{36}\.json$/i.test(f)) continue;
      try { const r = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8').replace(/^\uFEFF/, '')); if (r.session + '.json' === f) records.set(r.session, r); } catch { }
    }
  } catch { }
  return records;
}
// Windows cannot query another process's environment through supported process APIs. Match
// launch records by PID AND creation time, then inherit that marker down the verified parent tree.
function annotate(procs, records) {
  for (const r of records.values()) {
    const p = procs.find((p) => same(p, r.pid, r.created));
    if (p && !p.session) p.session = r.session;
  }
  for (let n = 0; n < procs.length; n++) {
    let changed = false;
    for (const p of procs) {
      if (p.session) continue;
      const parent = procs.find((x) => x.pid === p.ppid);
      if (parent?.session && Number.isFinite(parent.ageSec) && parent.ageSec >= p.ageSec) { p.session = parent.session; changed = true; }
    }
    if (!changed) break;
  }
}
function same(p, pid, created) { return Boolean(p && p.pid === pid && p.created && p.created === created); }
function choose(procs, records, opts) {
  const byPid = new Map(procs.map((p) => [p.pid, p]));
  const protectedPids = new Set();
  // A tree with an active manager session, remote session, daemon or another user's process stays.
  for (const p of procs) {
    let cur = p; const seen = new Set();
    while (cur && !seen.has(cur.pid)) {
      seen.add(cur.pid);
      if (cur.pid !== p.pid && /systemd --user/.test(cur.cmd || '')) break;
      const record = cur.session && records.get(cur.session);
      const active = record && !record.endedAt && same(byPid.get(record.ownerPid), record.ownerPid, record.ownerCreated);
      // pid 1 is everyone's ancestor; do not protect all descendants just because it is a service.
      if (cur.pid > 1 && (cur.pid === opts.selfPid || cur.uid !== opts.uid || cur.elevated !== false || PROTECTED.test(cur.cmd || cur.name) || active || (!p.session && AGENT.test(cur.cmd || '')))) {
        protectedPids.add(p.pid); break;
      }
      if (cur.ppid <= 1) break;
      const parent = byPid.get(cur.ppid);
      if (parent && Number.isFinite(cur.ageSec) && Number.isFinite(parent.ageSec) && parent.ageSec < cur.ageSec) break;
      cur = parent;
    }
  }
  const decisions = [];
  for (const p of procs) {
    if (p.pid <= 4 || protectedPids.has(p.pid) || !p.created || !Number.isFinite(p.ageSec) || p.ageSec < 0) continue;
    const parent = byPid.get(p.ppid);
    const parentGone = p.ppid <= 1 || !parent || (Number.isFinite(parent.ageSec) && parent.ageSec < p.ageSec) || /systemd --user/.test(parent.cmd || '');
    const record = p.session && records.get(p.session);
    const ended = record && (record.endedAt || !same(byPid.get(record.ownerPid), record.ownerPid, record.ownerCreated));
    if (p.session && (parentGone || ended)) {
      // Never signal a group containing even one protected/untagged/other-session member.
      const group = procs.filter((x) => x.pgid === p.pgid);
      const safeGroup = opts.platform !== 'win32' && p.pgid > 4 && group.length && group.every((x) => !protectedPids.has(x.pid) && x.session === p.session && x.uid === opts.uid && x.elevated === false);
      const tree = [];
      const visit = (pid, seen = new Set()) => {
        if (seen.has(pid)) return; seen.add(pid);
        for (const c of procs.filter((x) => x.ppid === pid && x.ageSec <= p.ageSec)) { tree.push(c); visit(c.pid, seen); }
      };
      visit(p.pid);
      if (opts.platform === 'win32' && tree.some((x) => protectedPids.has(x.pid) || x.uid !== opts.uid || x.elevated !== false || x.session !== p.session)) continue;
      decisions.push({ ...p, action: safeGroup || opts.platform === 'win32' ? 'end' : 'alert', reason: safeGroup || opts.platform === 'win32' ? 'tagged manager session ended or parent died' : 'tagged orphan shares an unverified process group', group: safeGroup ? p.pgid : null, tree: tree.map((x) => ({ pid: x.pid, created: x.created })) });
    } else if (!p.session && parentGone && p.ageSec >= 6 * 3600 && p.listening && RUNTIME.test(p.name)) {
      decisions.push({ ...p, action: 'alert', reason: 'untagged runtime orphan older than 6 hours holds a listening port' });
    }
  }
  return decisions.filter((d, i) => !d.group || decisions.findIndex((x) => x.group === d.group) === i);
}
async function scan(context, opts, log, adapters = {}) {
  const take = adapters.snapshot || snapshot;
  const initial = take();
  const records = adapters.sessions || sessions(context.aicmHome);
  annotate(initial.procs, records);
  const decisions = choose(initial.procs, records, { uid: initial.uid, selfPid: process.pid, platform: process.platform });
  for (const d of decisions) {
    const entry = { action: d.action === 'end' ? (opts.apply ? 'end' : 'would-end') : 'alert', reason: d.reason, pid: d.pid, name: d.name, created: d.created };
    if (opts.apply && d.action === 'end') {
      // PID reuse and changed ancestry/group membership are checked again just before signaling.
      const fresh = take();
      annotate(fresh.procs, records);
      const verified = choose(fresh.procs, records, { uid: fresh.uid, selfPid: process.pid, platform: process.platform }).find((x) => x.pid === d.pid && x.created === d.created && x.group === d.group && x.action === 'end' && JSON.stringify(x.tree) === JSON.stringify(d.tree));
      if (!verified) { entry.action = 'skip'; entry.reason = 'process identity or tree changed'; }
      else {
        try {
          if (adapters.kill) await adapters.kill(d);
          else if (d.group) await stopGroup(d.group, 1000, () => {
            const after = take(); annotate(after.procs, records);
            return choose(after.procs, records, { uid: after.uid, selfPid: process.pid, platform: process.platform }).some((p) => p.group === d.group && p.action === 'end' && p.session === d.session);
          });
          else {
            spawnSync('taskkill.exe', ['/PID', String(d.pid), '/T'], { windowsHide: true });
            await new Promise((r) => setTimeout(r, 1000));
            // If root exited, terminate remaining recorded descendants individually, after birth checks.
            const after = take();
            for (const p of [...d.tree].reverse().concat([{ pid: d.pid, created: d.created }])) {
              if (same(after.procs.find((x) => x.pid === p.pid), p.pid, p.created)) spawnSync('taskkill.exe', ['/PID', String(p.pid), '/F'], { windowsHide: true });
            }
          }
        } catch (e) { entry.action = 'error'; entry.reason = `termination failed (${e.code || 'unknown'})`; }
      }
    }
    log(entry);
  }
  return decisions;
}
module.exports = { snapshot, sessions, choose, scan, same };
