#!/usr/bin/env node
// Legacy process classifiers for compatibility. The CLI routes through ownership-aware
// automatic maintenance; --kill is --apply and untagged processes are always alert-only.
'use strict';

const path = require('path');

const MCP = /(\bmcp\b|[-_]mcp\b|\bmcp[-_]|@modelcontextprotocol|context7|serena|playwright-mcp|chrome-devtools-mcp)/i;
const AUTOMATION_BROWSER = /(chrome|chromium|msedge|headless_shell)/i;
const AUTOMATION_HINT = /(chrome-devtools-mcp|ms-playwright|puppeteer|--remote-debugging-pipe|--remote-debugging-port)/i;
const AGENT_CLI = /(^|[\\/])(claude|codex|opencode|gemini|qwen|grok|kimi|cursor-agent|copilot|amp|crush|goose|droid|auggie)(\.exe|\.cmd|\.js|\.mjs)?(\s|"|$)|node_modules[\\/](@anthropic-ai[\\/]claude-code|@openai[\\/]codex|opencode-ai|@google[\\/]gemini-cli|@qwen-code|@github[\\/]copilot|@xai-official[\\/]grok)/i;
const DESKTOP_APPS = /(AnthropicClaude|Programs[\\/]Claude[\\/]|Programs[\\/]OpenAI[\\/]Codex[\\/]Codex\.exe|Claude\.app|Codex\.app|Cursor\.app|Programs[\\/]cursor[\\/])/i;
const DEFAULT_IGNORE = /(app-server|daemon|paseo|sandbox|ollama|language-server|\blsp\b|typescript-language|pyright|copilot-language-server|--type=)/i;
// Anything inside a macOS app bundle is a GUI app (Goose.app, ...), and GUI apps always have launchd as parent.
const APP_BUNDLE = /\.app[\\/]Contents[\\/]/i;
// ps prints the path unquoted, so "/Applications/Some App.app/..." splits at the space: match the leading
// path up to the bundle, as long as no flag or second absolute path starts before it.
const APP_BUNDLE_LEAD = /^\s*\/(?:(?! [-/])[^"])*?\.app\/Contents\//i;
// Interpreters whose first non-flag argument is the program that actually runs.
const INTERPRETER = /^(node|nodejs|bun|deno|pythonw?[\d.]*|py)(\.exe)?$/i;

// One line of `ps -axo pid=,ppid=,etime=,rss=,lstart=,command=`; lstart is five words ("Wed Oct  7 10:00:00 2026").
function parsePsLine(line) {
  const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.*)$/.exec(line);
  if (!m) return null;
  const cmd = m[6];
  return { pid: +m[1], ppid: +m[2], ageSec: etimeSeconds(m[3]), mb: Math.round(+m[4] / 1024), created: m[5].replace(/\s+/g, ' '), cmd, name: path.basename(cmd.split(' ')[0]) };
}

// ps etime: [[dd-]hh:]mm:ss
function etimeSeconds(t) {
  const [d, rest] = t.includes('-') ? t.split('-') : ['0', t];
  const parts = rest.split(':').map(Number);
  while (parts.length < 3) parts.unshift(0);
  return (+d) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2];
}

// The program a command line runs: the executable, or for node/bun/deno/python the script (or -m module) after it.
function program(cmd) {
  const tokens = [];
  for (const m of cmd.matchAll(/"([^"]*)"|(\S+)/g)) tokens.push(m[1] !== undefined ? m[1] : m[2]);
  const exe = tokens[0] || '';
  if (!INTERPRETER.test(exe.split(/[\\/]/).pop())) return { exe, script: '' };
  for (let i = 1; i < tokens.length; i++) {
    const t = tokens[i];
    if (t === '-m') return { exe, script: tokens[i + 1] || '' };
    if (t === '-c' || t === '-e' || t === '--eval') return { exe, script: '' }; // inline code, no program file
    if (t.startsWith('-') || (i === 1 && (t === 'run' || t === 'x'))) continue; // flags, `bun run`, `deno run`
    return { exe, script: t };
  }
  return { exe, script: '' };
}

function classify(p) {
  const cmd = p.cmd || '';
  const text = `${p.name || ''} ${cmd}`;
  if (DESKTOP_APPS.test(cmd)) return '';
  if (AUTOMATION_BROWSER.test(p.name || '') && AUTOMATION_HINT.test(cmd)) return 'browser';
  const { exe, script } = program(cmd);
  if (APP_BUNDLE.test(exe) || APP_BUNDLE.test(script) || APP_BUNDLE_LEAD.test(cmd)) return '';
  // Only the program decides "agent": an agent CLI started with --mcp-config is still the agent, and
  // `python -m http.server --directory /srv/amp` is not one just because an argument says "amp".
  if (AGENT_CLI.test(exe) || AGENT_CLI.test(script) || AGENT_CLI.test(p.name || '')) return 'agent';
  if (MCP.test(text)) return 'mcp';
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
    // Unknown age (null/undefined) is never left behind: we cannot tell how long it has run.
    if (!Number.isFinite(p.ageSec) || p.ageSec < opts.minAgeHours * 3600) continue;
    const parent = byPid.get(p.ppid);
    let gone;
    if (opts.platform === 'win32') {
      // A parent that started after the child is an unrelated process that reused the PID.
      // A parent of unknown age is kept: it may well be the real one.
      gone = !parent || (Number.isFinite(parent.ageSec) && parent.ageSec < p.ageSec);
    } else {
      // Only pid 1 (launchd/init/systemd) or a `systemd --user` reaper means the session is gone. WSL runs each
      // session started from Windows (`wsl.exe claude`) under its own process named init that is not pid 1;
      // that one is a live parent.
      gone = p.ppid === 1 || Boolean(parent && /systemd --user/.test(parent.cmd || ''));
    }
    if (!gone) continue;
    // Count the whole tree under it.
    const tree = [];
    const stack = [...(children.get(p.pid) || [])];
    while (stack.length) { const c = stack.pop(); tree.push(c); stack.push(...(children.get(c.pid) || [])); }
    orphans.push({
      pid: p.pid, name: p.name, kind, ageHours: Math.round(p.ageSec / 3600), started: p.created || '', children: tree.length,
      mb: (p.mb || 0) + tree.reduce((s, c) => s + (c.mb || 0), 0), cmd: (p.cmd || '').slice(0, 160), tree: tree.map((c) => c.pid),
    });
  }
  return orphans;
}

// The legacy classifier remains available for reports/tests. All executable process maintenance
// uses the ownership-aware scanner; --kill is an explicit --apply alias, never a name-based kill.
async function main(argv) {
  const args = ['--processes-only'];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--min-age-hours') { i++; continue; } // compatibility; alert threshold stays >=6h
    args.push(argv[i] === '--kill' ? '--apply' : argv[i]);
  }
  return require('./auto-maintenance').main(args);
}
if (require.main === module) main(process.argv.slice(2)).then((code) => { process.exitCode = code; });
module.exports = { classify, findOrphans, etimeSeconds, parsePsLine };
