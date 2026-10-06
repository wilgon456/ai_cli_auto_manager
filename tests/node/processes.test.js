// Tests for lib/processes.js with injected process lists; nothing is ever killed for real.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'processes.js');
const { classify, findOrphans, etimeSeconds } = require(MODULE);
const H = 3600;

test('classify', () => {
  assert.strictEqual(classify({ name: 'node.exe', cmd: 'node C:/x/node_modules/chrome-devtools-mcp/build/index.js' }), 'mcp');
  assert.strictEqual(classify({ name: 'claude.exe', cmd: '"C:/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe" --mcp-config x.json' }), 'agent');
  assert.strictEqual(classify({ name: 'chrome.exe', cmd: 'chrome.exe --remote-debugging-pipe --user-data-dir=C:/u/.cache/chrome-devtools-mcp/p' }), 'browser');
  assert.strictEqual(classify({ name: 'chrome.exe', cmd: 'chrome.exe --profile-directory=Default' }), '', 'a normal browser is not ours');
  assert.strictEqual(classify({ name: 'claude.exe', cmd: 'C:/Users/u/AppData/Local/AnthropicClaude/app-1.0/claude.exe' }), '', 'desktop app is not a CLI session');
  assert.strictEqual(classify({ name: 'bash', cmd: '/bin/bash -l' }), '');
});

test('etime parsing', () => {
  assert.strictEqual(etimeSeconds('05:07'), 307);
  assert.strictEqual(etimeSeconds('02:00:00'), 7200);
  assert.strictEqual(etimeSeconds('3-01:00:00'), 3 * 86400 + 3600);
});

const winList = [
  { pid: 100, ppid: 1, name: 'explorer.exe', cmd: 'explorer.exe', ageSec: 50 * H, mb: 100 },
  // live session: claude -> chrome-devtools-mcp -> chrome
  { pid: 200, ppid: 100, name: 'claude.exe', cmd: 'C:/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe', ageSec: 10 * H, mb: 300 },
  { pid: 201, ppid: 200, name: 'node.exe', cmd: 'node chrome-devtools-mcp', ageSec: 10 * H, mb: 50 },
  // parent gone: MCP server with a child browser
  { pid: 300, ppid: 999, name: 'node.exe', cmd: 'node chrome-devtools-mcp', ageSec: 26 * H, mb: 60 },
  { pid: 301, ppid: 300, name: 'chrome.exe', cmd: 'chrome.exe --type=renderer', ageSec: 26 * H, mb: 200 },
  // PID reuse: "parent" 400 started after the child, so the real parent is gone
  { pid: 400, ppid: 100, name: 'notepad.exe', cmd: 'notepad.exe', ageSec: 1 * H, mb: 10 },
  { pid: 401, ppid: 400, name: 'node.exe', cmd: 'npx -y @modelcontextprotocol/server-filesystem', ageSec: 5 * H, mb: 40 },
  // parent gone but too young
  { pid: 500, ppid: 998, name: 'node.exe', cmd: 'node some-mcp-server', ageSec: 0.5 * H, mb: 40 },
  // parent gone but a daemon on purpose
  { pid: 600, ppid: 997, name: 'node.exe', cmd: 'node paseo daemon', ageSec: 40 * H, mb: 90 },
  { pid: 601, ppid: 996, name: 'codex.exe', cmd: 'codex app-server --listen', ageSec: 40 * H, mb: 90 },
  // parent gone but not agent-related
  { pid: 700, ppid: 995, name: 'node.exe', cmd: 'node server.js', ageSec: 40 * H, mb: 90 },
];

test('finds left-behind agent processes on Windows rules', () => {
  const o = findOrphans(winList, { platform: 'win32', minAgeHours: 2, selfPid: -1 });
  assert.deepStrictEqual(o.map((x) => x.pid).sort(), [300, 401]);
  const mcp = o.find((x) => x.pid === 300);
  assert.strictEqual(mcp.children, 1);
  assert.strictEqual(mcp.mb, 260);
});

test('unix: reparented to init counts as left behind', () => {
  const list = [
    { pid: 1, ppid: 0, name: 'launchd', cmd: '/sbin/launchd', ageSec: 99 * H },
    { pid: 50, ppid: 1, name: 'node', cmd: 'node /x/node_modules/@playwright/mcp/cli.js', ageSec: 5 * H, mb: 30 },
    { pid: 60, ppid: 70, name: 'node', cmd: 'node /x/serena-mcp', ageSec: 5 * H, mb: 30 },
    { pid: 70, ppid: 1, name: 'zsh', cmd: '-zsh', ageSec: 9 * H },
  ];
  const o = findOrphans(list, { platform: 'darwin', minAgeHours: 2, selfPid: -1 });
  assert.deepStrictEqual(o.map((x) => x.pid), [50]);
});

test('never touches its own process tree', () => {
  const list = [{ pid: 10, ppid: 999, name: 'node', cmd: 'node mcp-thing', ageSec: 9 * H }, { pid: 11, ppid: 10, name: 'node', cmd: 'node processes.js', ageSec: 9 * H }];
  assert.strictEqual(findOrphans(list, { platform: 'win32', minAgeHours: 2, selfPid: 11 }).length, 0);
});

test('CLI: report, announce once, --kill only records on injected lists', () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-proc-'));
  try {
    const listFile = path.join(work, 'list.json');
    const killLog = path.join(work, 'kills.log');
    fs.writeFileSync(listFile, JSON.stringify(winList));
    const env = { ...process.env, AICM_HOME: path.join(work, 'aicm'), AICM_PROCESS_LIST: listFile, AICM_KILL_LOG: killLog, AICM_PLATFORM: 'win32' };
    const run = (args) => spawnSync(process.execPath, [MODULE, ...args], { encoding: 'utf8', env }).stdout;
    const first = run([]);
    assert.match(first, /left running +mcp +pid 300 node\.exe, 26h, 260 MB with 1 children/);
    assert.match(first, /2 left-behind agent processes \(300 MB\)/);
    assert.match(first, /attention: mcp node\.exe \(pid 300\)/);
    assert.ok(!fs.existsSync(killLog), 'report mode kills nothing');
    assert.doesNotMatch(run([]), /attention:/, 'announced once');
    const killed = run(['--kill']);
    assert.match(killed, /ended +mcp +pid 300/);
    assert.match(fs.readFileSync(killLog, 'utf8'), /kill 300 tree=301/);
  } finally { fs.rmSync(work, { recursive: true, force: true }); }
});
