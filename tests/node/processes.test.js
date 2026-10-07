// Tests for lib/processes.js with injected process lists; nothing is ever killed for real.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'processes.js');
const { classify, findOrphans, etimeSeconds, parsePsLine } = require(MODULE);
const H = 3600;

test('classify', () => {
  assert.strictEqual(classify({ name: 'node.exe', cmd: 'node C:/x/node_modules/chrome-devtools-mcp/build/index.js' }), 'mcp');
  assert.strictEqual(classify({ name: 'claude.exe', cmd: '"C:/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe" --mcp-config x.json' }), 'agent');
  assert.strictEqual(classify({ name: 'chrome.exe', cmd: 'chrome.exe --remote-debugging-pipe --user-data-dir=C:/u/.cache/chrome-devtools-mcp/p' }), 'browser');
  assert.strictEqual(classify({ name: 'chrome.exe', cmd: 'chrome.exe --profile-directory=Default' }), '', 'a normal browser is not ours');
  assert.strictEqual(classify({ name: 'claude.exe', cmd: 'C:/Users/u/AppData/Local/AnthropicClaude/app-1.0/claude.exe' }), '', 'desktop app is not a CLI session');
  assert.strictEqual(classify({ name: 'bash', cmd: '/bin/bash -l' }), '');
});

test('classify: macOS app bundles are never agent or MCP', () => {
  assert.strictEqual(classify({ name: 'Goose', cmd: '/Applications/Goose.app/Contents/MacOS/Goose' }), '');
  assert.strictEqual(classify({ name: 'Some', cmd: '/Applications/Some App.app/Contents/MacOS/goose-mcp --stdio' }), '', 'unquoted path with a space');
  assert.strictEqual(classify({ name: 'node', cmd: '"/Applications/Foo.app/Contents/MacOS/node" /Applications/Foo.app/Contents/Resources/mcp-server.js' }), '');
  assert.strictEqual(classify({ name: 'node', cmd: 'node /x/node_modules/@playwright/mcp/cli.js --executable-path /Applications/Google Chrome.app/Contents/MacOS/Google Chrome' }), 'mcp',
    'a bundle path in the arguments does not hide a real MCP server');
});

test('classify: only the program decides "agent", not its arguments', () => {
  assert.strictEqual(classify({ name: 'python', cmd: 'python -m http.server --directory /srv/amp' }), '');
  assert.strictEqual(classify({ name: 'node', cmd: 'node /srv/app/server.js --name goose --dir /home/u/amp' }), '');
  assert.strictEqual(classify({ name: 'tail', cmd: 'tail -f /var/log/claude' }), '');
  assert.strictEqual(classify({ name: 'node', cmd: 'node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume' }), 'agent');
  assert.strictEqual(classify({ name: 'node', cmd: 'node --max-old-space-size=4096 /usr/lib/node_modules/@openai/codex/bin/codex.js' }), 'agent');
  assert.strictEqual(classify({ name: 'bun', cmd: 'bun run /home/u/bin/opencode.js' }), 'agent');
  assert.strictEqual(classify({ name: 'claude.exe', cmd: 'claude.exe --continue' }), 'agent', 'bare executable name');
  assert.strictEqual(classify({ name: 'amp', cmd: '/home/u/.local/bin/amp' }), 'agent');
});

test('etime parsing', () => {
  assert.strictEqual(etimeSeconds('05:07'), 307);
  assert.strictEqual(etimeSeconds('02:00:00'), 7200);
  assert.strictEqual(etimeSeconds('3-01:00:00'), 3 * 86400 + 3600);
});

test('ps line parsing keeps the start time as stable text', () => {
  const p = parsePsLine('  4242     1   02:00:00  20480 Wed Oct  7 10:00:00 2026     node /x/serena-mcp --stdio');
  assert.deepStrictEqual(p, { pid: 4242, ppid: 1, ageSec: 7200, mb: 20, created: 'Wed Oct 7 10:00:00 2026', cmd: 'node /x/serena-mcp --stdio', name: 'node' });
  assert.strictEqual(parsePsLine('garbage'), null);
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

test('macOS: a GUI app under launchd is not left behind', () => {
  const list = [
    { pid: 1, ppid: 0, name: 'launchd', cmd: '/sbin/launchd', ageSec: 99 * H },
    { pid: 80, ppid: 1, name: 'Goose', cmd: '/Applications/Goose.app/Contents/MacOS/Goose', ageSec: 30 * H, mb: 400 },
  ];
  assert.strictEqual(findOrphans(list, { platform: 'darwin', minAgeHours: 2, selfPid: -1 }).length, 0);
});

test('WSL: a per-session init that is not pid 1 is a live parent', () => {
  const list = [
    { pid: 1, ppid: 0, name: 'init', cmd: '/init', ageSec: 99 * H },
    // session started from Windows with `wsl.exe claude`: WSL gives it its own init
    { pid: 8, ppid: 1, name: 'init', cmd: '/init', ageSec: 9 * H },
    { pid: 9, ppid: 8, name: 'claude', cmd: 'claude', ageSec: 9 * H },
    { pid: 10, ppid: 9, name: 'node', cmd: 'node /x/serena-mcp', ageSec: 9 * H },
    // MCP server started directly by the session init: still alive
    { pid: 11, ppid: 8, name: 'node', cmd: 'node /x/context7-mcp', ageSec: 9 * H },
    // handed to pid 1: left behind
    { pid: 12, ppid: 1, name: 'node', cmd: 'node /x/playwright-mcp', ageSec: 9 * H },
    // handed to a `systemd --user` reaper: left behind
    { pid: 20, ppid: 1, name: 'systemd', cmd: '/lib/systemd/systemd --user', ageSec: 99 * H },
    { pid: 21, ppid: 20, name: 'node', cmd: 'node /x/chrome-devtools-mcp', ageSec: 9 * H },
  ];
  const o = findOrphans(list, { platform: 'linux', minAgeHours: 2, selfPid: -1 });
  assert.deepStrictEqual(o.map((x) => x.pid).sort((a, b) => a - b), [12, 21]);
});

test('Windows: an unknown age never makes an orphan', () => {
  const list = [
    // parent age unknown: keep, it may be the real parent
    { pid: 10, ppid: 1, name: 'pwsh.exe', cmd: 'pwsh.exe', ageSec: null },
    { pid: 11, ppid: 10, name: 'node.exe', cmd: 'node chrome-devtools-mcp', ageSec: 5 * H },
    { pid: 12, ppid: 1, name: 'cmd.exe', cmd: 'cmd.exe' },
    { pid: 13, ppid: 12, name: 'node.exe', cmd: 'node serena-mcp', ageSec: 5 * H },
    // own age unknown, parent gone: still not reported
    { pid: 20, ppid: 999, name: 'node.exe', cmd: 'node context7-mcp', ageSec: null },
    { pid: 21, ppid: 998, name: 'node.exe', cmd: 'node playwright-mcp' },
  ];
  assert.strictEqual(findOrphans(list, { platform: 'win32', minAgeHours: 2, selfPid: -1 }).length, 0);
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

test('CLI: attention stays quiet as the process ages; a reused pid is announced again', () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-proc-'));
  try {
    const listFile = path.join(work, 'list.json');
    const env = { ...process.env, AICM_HOME: path.join(work, 'aicm'), AICM_PROCESS_LIST: listFile, AICM_KILL_LOG: path.join(work, 'kills.log'), AICM_PLATFORM: 'win32' };
    const run = (list) => { fs.writeFileSync(listFile, JSON.stringify(list)); return spawnSync(process.execPath, [MODULE], { encoding: 'utf8', env }).stdout; };
    const orphan = (ageSec, created) => [{ pid: 300, ppid: 999, name: 'node.exe', cmd: 'node chrome-devtools-mcp', ageSec, created, mb: 60 }];
    const first = run(orphan(26 * H, '2026-10-06T08:00:00.0000000Z'));
    assert.match(first, /attention: mcp node\.exe \(pid 300, started 2026-10-06T08:00:00\.0000000Z\) left running after its session ended/);
    assert.doesNotMatch(first, /attention: .*\d+h/, 'no hours in the attention text');
    assert.doesNotMatch(run(orphan(27 * H, '2026-10-06T08:00:00.0000000Z')), /attention:/, 'an hour older is the same item');
    assert.match(run(orphan(3 * H, '2026-10-07T07:00:00.0000000Z')), /attention: mcp node\.exe \(pid 300, started 2026-10-07/, 'reused pid is a new item');
  } finally { fs.rmSync(work, { recursive: true, force: true }); }
});
