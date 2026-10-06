// Tests for lib/config-drift.js against a throwaway home folder.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'config-drift.js');
const { codexMcp } = require(MODULE);

function write(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}

function run(home, args = []) {
  const env = { ...process.env, HOME: home, USERPROFILE: home, AICM_HOME: path.join(home, '.aicm'), AICM_ASSUME_INSTALLED: '1' };
  const r = spawnSync(process.execPath, [MODULE, ...args], { encoding: 'utf8', env });
  assert.strictEqual(r.status, 0, r.stderr);
  return r.stdout;
}

test('codex MCP tables without sub-tables', () => {
  assert.deepStrictEqual(codexMcp('[mcp_servers.a]\ncommand="x"\n[mcp_servers.a.env]\nK="v"\n[mcp_servers."b-c"]\n[other]\n'), ['a', 'b-c']);
});

test('reports MCP gaps, skills some CLIs cannot see, and conflicting skill copies', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-cfg-'));
  try {
    write(path.join(home, '.claude.json'), JSON.stringify({ mcpServers: { github: {}, playwright: {} } }));
    write(path.join(home, '.codex', 'config.toml'), '[mcp_servers.github]\ncommand = "gh"\n[mcp_servers.github.env]\nX = "1"\n[mcp_servers.notion]\n');
    // Gemini settings with a comment and a trailing comma, as people write them
    write(path.join(home, '.gemini', 'settings.json'), '{\n  // mine\n  "mcpServers": { "github": {}, },\n}\n');
    write(path.join(home, '.claude', 'skills', 'review', 'SKILL.md'), 'v1');
    write(path.join(home, '.agents', 'skills', 'review', 'SKILL.md'), 'v2');
    write(path.join(home, '.claude', 'skills', 'deploy', 'SKILL.md'), 'same');
    write(path.join(home, '.agents', 'skills', 'deploy', 'SKILL.md'), 'same');
    write(path.join(home, '.claude', 'skills', 'only-claude', 'SKILL.md'), 'x');

    const out = run(home);
    assert.match(out, /Claude Code: github, playwright/);
    assert.match(out, /Codex: github, notion/);
    assert.match(out, /Gemini CLI: github/);
    assert.match(out, /playwright: in Claude Code; missing in Codex, Gemini CLI/);
    assert.match(out, /notion: in Codex; missing in Claude Code, Gemini CLI/);
    assert.doesNotMatch(out, /^\s+github:/m, 'a server every CLI has is not a gap');
    assert.match(out, /only-claude: not in ~\/\.agents\/skills/);
    assert.match(out, /review: ~\/\.claude\/skills \(\w+\) vs ~\/\.agents\/skills \(\w+\)/);
    assert.doesNotMatch(out, /deploy: ~/, 'identical copies are not a conflict');
    assert.match(out, /attention: skill "review" differs/);
    assert.doesNotMatch(run(home), /attention:/, 'announced once');
    assert.match(run(home, ['--markdown']), /### MCP servers per CLI/);
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
