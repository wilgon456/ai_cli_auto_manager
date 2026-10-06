#!/usr/bin/env node
// Finds processes that AI agent sessions left behind: MCP servers, automation browsers and agent CLIs
// whose parent session is gone.
//
//   node processes.js [--kill] [--min-age-hours 2] [--json]
//
// Report only unless --kill (or AICM_KILL_ORPHANS=1) is given. A process counts as left behind when it
// looks agent-related, has run for at least --min-age-hours, and its parent no longer exists (Windows),
// or it was handed to init/launchd/systemd (macOS/Linux). Long-running daemons (Paseo, Codex app-server,
// sandboxes, language servers, ...) and this tool's own process tree are never touched; add more with
// AICM_PROCESS_IGNORE (a regular expression matched against the command line).
// --kill ends the left-behind process together with its children.
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const common = require('./node-common');

const MCP = /(\bmcp\b|[-_]mcp\b|\bmcp[-_]|@modelcontextprotocol|context7|serena|playwright-mcp|chrome-devtools-mcp)/i;
const AUTOMATION_BROWSER = /(chrome|chromium|msedge|headless_shell)/i;
const AUTOMATION_HINT = /(chrome-devtools-mcp|ms-playwright|puppeteer|--remote-debugging-pipe|--remote-debugging-port)/i;
const AGENT_CLI = /(^|[\\/])(claude|codex|opencode|gemini|qwen|grok|kimi|cursor-agent|copilot|amp|crush|goose|droid|auggie)(\.exe|\.cmd|\.js|\.mjs)?(\s|"|$)|node_modules[\\/](@anthropic-ai[\\/]claude-code|@openai[\\/]codex|opencode-ai|@google[\\/]gemini-cli|@qwen-code|@github[\\/]copilot|@xai-official[\\/]grok)/i;
const DESKTOP_APPS = /(AnthropicClaude|Programs[\\/]Claude[\\/]|Programs[\\/]OpenAI[\\/]Codex[\\/]Codex\.exe|Claude\.app|Codex\.app|Cursor\.app|Programs[\\/]cursor[\\/])/i;
const DEFAULT_IGNORE = /(app-server|daemon|paseo|sandbox|ollama|language-server|\blsp\b|typescript-language|pyright|copilot-language-server|--type=)/i;
const INIT_NAMES = /^(launchd|init|systemd)$/i;

function listProcesses() {
  if (process.env.AICM_PROCESS_LIST) return JSON.parse(fs.readFileSync(process.env.AICM_PROCESS_LIST, 'utf8'));
  if (process.platform === 'win32') {
    const ps = "Get-CimInstance Win32_Process | ForEach-Object { [pscustomobject]@{ pid = [int]$_.ProcessId; ppid = [int]$_.ParentProcessId; name = $_.Name; cmd = [string]$_.CommandLine; mb = [int]($_.WorkingSetSize / 1MB); created = $(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { '' }) } } | ConvertTo-Json -Compress";
    const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024 });
    const now = Date.now();
    return JSON.parse(r.stdout || '[]').map((p) => ({ ...p, ageSec: p.created ? Math.round((now - Date.parse(p.created)) / 1000) : 0 }));
  }
  const r = spawnSync('ps', ['-axo', 'pid=,ppid=,etime=,rss=,command='], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return (r.stdout || '').split('\n').filter(Boolean).map((line) => {
    const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(.*)$/.exec(line);
    if (!m) return null;
    const cmd = m[5];
    return { pid: +m[1], ppid: +m[2], ageSec: etimeSeconds(m[3]), mb: Math.round(+m[4] / 1024), cmd, name: path.basename(cmd.split(' ')[0]) };
  }).filter(Boolean);
}

// ps etime: [[dd-]hh:]mm:ss
function etimeSeconds(t) {
  const [d, rest] = t.includes('-') ? t.split('-') : ['0', t];
  const parts = rest.split(':').map(Number);
  while (parts.length < 3) parts.unshift(0);
  return (+d) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2];
}

function classify(p) {
  const cmd = p.cmd || '';
  const text = `${p.name || ''} ${cmd}`;
  if (DESKTOP_APPS.test(cmd)) return '';
  if (AUTOMATION_BROWSER.test(p.name || '') && AUTOMATION_HINT.test(cmd)) return 'browser';
  // The executable decides first: an agent CLI started with --mcp-config is still the agent.
  const exe = (/^\s*"([^"]+)"/.exec(cmd) || /^\s*(\S+)/.exec(cmd) || [])[1] || '';
  if (AGENT_CLI.test(` ${exe} `) || AGENT_CLI.test(` ${p.name || ''} `)) return 'agent';
  if (MCP.test(text)) return 'mcp';
  if (AGENT_CLI.test(cmd)) return 'agent';
  return '';
}

function findOrphans(procs, opts) {
  const byPid = new Map(procs.map((p) => [p.pid, p]));
  const children = new Map();
  for (const p of procs) {
    if (!children.has(p.ppid)) children.set(p.ppid, []);
    children.get(p.ppid).push(p);
  }
  // Never touch this tool's own process tree.
  const own = new Set();
  for (let cur = byPid.get(opts.selfPid); cur && !own.has(cur.pid); cur = byPid.get(cur.ppid)) own.add(cur.pid);
  const ignore = process.env.AICM_PROCESS_IGNORE ? new RegExp(process.env.AICM_PROCESS_IGNORE, 'i') : null;

  const orphans = [];
  for (const p of procs) {
    if (own.has(p.pid) || p.pid <= 4) continue;
    const kind = classify(p);
    if (!kind) continue;
    if (DEFAULT_IGNORE.test(p.cmd || '') || (ignore && ignore.test(`${p.name} ${p.cmd}`))) continue;
    if (p.ageSec < opts.minAgeHours * 3600) continue;
    const parent = byPid.get(p.ppid);
    let gone;
    if (opts.platform === 'win32') {
      // A parent that started after the child is an unrelated process that reused the PID.
      gone = !parent || (parent.ageSec !== undefined && parent.ageSec < p.ageSec);
    } else {
      gone = p.ppid === 1 || (parent && INIT_NAMES.test(parent.name || '')) || (parent && /systemd --user/.test(parent.cmd || ''));
    }
    if (!gone) continue;
    // Count the whole tree under it.
    const tree = [];
    const stack = [...(children.get(p.pid) || [])];
    while (stack.length) { const c = stack.pop(); tree.push(c); stack.push(...(children.get(c.pid) || [])); }
    orphans.push({
      pid: p.pid, name: p.name, kind, ageHours: Math.round(p.ageSec / 3600), children: tree.length,
      mb: (p.mb || 0) + tree.reduce((s, c) => s + (c.mb || 0), 0), cmd: (p.cmd || '').slice(0, 160), tree: tree.map((c) => c.pid),
    });
  }
  return orphans;
}

function killTree(o, opts) {
  if (opts.fake) { fs.appendFileSync(opts.fake, `kill ${o.pid} tree=${o.tree.join(',')}\n`); return true; }
  if (opts.platform === 'win32') {
    return spawnSync('taskkill', ['/PID', String(o.pid), '/T', '/F'], { windowsHide: true }).status === 0;
  }
  let ok = true;
  for (const pid of [...o.tree].reverse().concat([o.pid])) {
    try { process.kill(pid, 'SIGTERM'); } catch { ok = false; }
  }
  return ok;
}

function main(argv) {
  const opts = { kill: process.env.AICM_KILL_ORPHANS === '1', minAgeHours: Number(process.env.AICM_ORPHAN_MIN_AGE_HOURS || 2), json: false, selfPid: process.pid, platform: process.env.AICM_PLATFORM || process.platform, fake: process.env.AICM_KILL_LOG || '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--kill') opts.kill = true;
    else if (a === '--json') opts.json = true;
    else if (a === '--min-age-hours') opts.minAgeHours = Number(argv[++i]);
    else if (a === '-h' || a === '--help') { console.log('usage: processes.js [--kill] [--min-age-hours 2] [--json]'); return 0; }
    else { console.error(`unknown argument: ${a}`); return 2; }
  }
  if (process.env.AICM_PROCESS_LIST && !opts.fake) opts.fake = path.join(require('os').tmpdir(), 'aicm-kill.log'); // never kill for real on injected lists
  const { aicmHome } = common.paths();
  let orphans;
  try { orphans = findOrphans(listProcesses(), opts); } catch (e) { console.log(`processes: could not list processes (${e.message})`); return 0; }
  for (const o of orphans) o.action = opts.kill ? (killTree(o, opts) ? 'ended' : 'end failed') : 'left running';
  const totalMb = orphans.reduce((s, o) => s + o.mb, 0);
  const summary = `${orphans.length} left-behind agent processes (${totalMb} MB)${orphans.length && !opts.kill ? '; end them with --kill or AICM_KILL_ORPHANS=1' : ''}`;
  common.writeState(aicmHome, 'processes', { finishedAt: new Date().toISOString(), kill: opts.kill, summary, orphans });
  if (opts.json) { console.log(JSON.stringify({ summary, orphans }, null, 2)); return 0; }
  for (const o of orphans) console.log(`${o.action.padEnd(12)} ${o.kind.padEnd(7)} pid ${o.pid} ${o.name}, ${o.ageHours}h, ${o.mb} MB${o.children ? ` with ${o.children} children` : ''}: ${o.cmd}`);
  console.log(summary);
  const attention = orphans.filter((o) => o.action !== 'ended').map((o) => `${o.kind} ${o.name} (pid ${o.pid}) left running ${o.ageHours}h after its session ended`);
  for (const a of common.newSince(aicmHome, 'processes-attention', attention)) console.log(`attention: ${a}`);
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = { classify, findOrphans, etimeSeconds };
