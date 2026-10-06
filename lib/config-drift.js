#!/usr/bin/env node
// Compares what the installed AI CLIs are configured with: user-level MCP servers and skills.
//
//   node config-drift.js [--markdown] [--json]
//
// Report only; nothing is changed. Flags:
//   - MCP servers set up in some CLIs but not in others
//   - skills with the same name in several skill folders but different SKILL.md content (one silently
//     wins over the other depending on which folder a CLI reads first)
// Only CLIs that are installed (command on PATH) and have a config file are compared.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const common = require('./node-common');

// True when `name` is an executable on PATH (Windows: with any PATHEXT extension).
function commandExists(name) {
  if (process.env.AICM_ASSUME_INSTALLED === '1') return true;
  const exts = process.platform === 'win32' ? (process.env.PATHEXT || '.EXE;.CMD;.BAT;.PS1').split(';').concat(['.ps1', '']) : [''];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    for (const ext of exts) {
      try { if (dir && fs.statSync(path.join(dir, name + ext.toLowerCase())).isFile()) return true; } catch { /* next */ }
    }
  }
  return false;
}

function keysOf(obj) { return obj && typeof obj === 'object' ? Object.keys(obj).sort() : []; }

// [mcp_servers.name] tables, without sub-tables such as [mcp_servers.name.env].
function codexMcp(text) {
  const names = new Set();
  for (const m of text.matchAll(/^\s*\[mcp_servers\.("([^"]+)"|[A-Za-z0-9_-]+)\]\s*$/gm)) names.add(m[2] || m[1]);
  return [...names].sort();
}

function mcpSources(home) {
  return [
    { cli: 'Claude Code', cmd: 'claude', file: path.join(home, '.claude.json'), read: (f) => keysOf(common.readJson(f).mcpServers) },
    { cli: 'Codex', cmd: 'codex', file: path.join(home, '.codex', 'config.toml'), read: (f) => codexMcp(fs.readFileSync(f, 'utf8')) },
    { cli: 'Gemini CLI', cmd: 'gemini', file: path.join(home, '.gemini', 'settings.json'), read: (f) => keysOf(common.readJson(f).mcpServers) },
    { cli: 'Qwen Code', cmd: 'qwen', file: path.join(home, '.qwen', 'settings.json'), read: (f) => keysOf(common.readJson(f).mcpServers) },
    { cli: 'OpenCode', cmd: 'opencode', file: path.join(home, '.config', 'opencode', 'opencode.json'), read: (f) => keysOf(common.readJson(f).mcp) },
    { cli: 'Cursor', cmd: 'cursor-agent', file: path.join(home, '.cursor', 'mcp.json'), read: (f) => keysOf(common.readJson(f).mcpServers) },
    { cli: 'Copilot CLI', cmd: 'copilot', file: path.join(home, '.copilot', 'mcp-config.json'), read: (f) => keysOf(common.readJson(f).mcpServers) },
  ];
}

function skillFolders(home) {
  return [
    { folder: path.join(home, '.claude', 'skills'), readBy: 'Claude Code' },
    { folder: path.join(home, '.codex', 'skills'), readBy: 'Codex' },
    { folder: path.join(home, '.agents', 'skills'), readBy: 'Codex, OpenCode and other agents' },
    { folder: path.join(home, '.gemini', 'skills'), readBy: 'Gemini CLI' },
    { folder: path.join(home, '.qwen', 'skills'), readBy: 'Qwen Code' },
  ];
}

function collect(home) {
  const mcp = [];
  for (const s of mcpSources(home)) {
    if (!fs.existsSync(s.file) || !commandExists(s.cmd)) continue;
    try { mcp.push({ cli: s.cli, servers: s.read(s.file) }); } catch (e) { mcp.push({ cli: s.cli, servers: [], error: `unreadable: ${e.message.split('\n')[0]}` }); }
  }
  const skills = new Map(); // name -> [{folder, hash}]
  const folders = [];
  for (const s of skillFolders(home)) {
    let entries;
    try { entries = fs.readdirSync(s.folder, { withFileTypes: true }); } catch { continue; }
    folders.push({ folder: s.folder, readBy: s.readBy, count: 0 });
    for (const e of entries) {
      const file = path.join(s.folder, e.name, 'SKILL.md');
      if (!fs.existsSync(file)) continue;
      folders[folders.length - 1].count++;
      const hash = crypto.createHash('sha1').update(fs.readFileSync(file)).digest('hex').slice(0, 10);
      if (!skills.has(e.name)) skills.set(e.name, []);
      skills.get(e.name).push({ folder: s.folder, hash });
    }
  }
  return { mcp, skills, folders };
}

function analyse({ mcp, skills, folders }, home) {
  const readable = mcp.filter((m) => !m.error);
  const allServers = [...new Set(readable.flatMap((m) => m.servers))].sort();
  const mcpGaps = [];
  if (readable.length > 1) {
    for (const name of allServers) {
      const have = readable.filter((m) => m.servers.includes(name)).map((m) => m.cli);
      if (have.length < readable.length) mcpGaps.push({ server: name, in: have, missing: readable.filter((m) => !have.includes(m.cli)).map((m) => m.cli) });
    }
  }
  const conflicts = [];
  for (const [name, copies] of [...skills.entries()].sort()) {
    if (copies.length > 1 && new Set(copies.map((c) => c.hash)).size > 1) {
      conflicts.push({ skill: name, copies: copies.map((c) => ({ folder: common.display(c.folder, home), hash: c.hash })) });
    }
  }
  const skillGaps = [];
  if (folders.length > 1) {
    for (const [name, copies] of [...skills.entries()].sort()) {
      if (copies.length < folders.length) {
        const inside = copies.map((c) => c.folder);
        skillGaps.push({ skill: name, missing: folders.filter((f) => !inside.includes(f.folder)).map((f) => common.display(f.folder, home)) });
      }
    }
  }
  return { mcp, folders: folders.map((f) => ({ ...f, folder: common.display(f.folder, home) })), mcpGaps, conflicts, skillGaps };
}

function render(result, markdown) {
  const lines = [];
  const h = (t) => lines.push(markdown ? `### ${t}` : `== ${t} ==`);
  h('MCP servers per CLI');
  for (const m of result.mcp) lines.push(`${markdown ? '- ' : ''}${m.cli}: ${m.error || m.servers.join(', ') || '(none)'}`);
  if (result.mcpGaps.length) {
    lines.push(markdown ? '' : '');
    lines.push('Set up in some CLIs only:');
    for (const g of result.mcpGaps) lines.push(`${markdown ? '- ' : '  '}${g.server}: in ${g.in.join(', ')}; missing in ${g.missing.join(', ')}`);
  }
  lines.push('');
  h('Skill folders');
  for (const f of result.folders) lines.push(`${markdown ? '- ' : ''}${f.folder}: ${f.count} skills (read by ${f.readBy})`);
  if (result.skillGaps.length) {
    lines.push('');
    lines.push('Skills some CLIs cannot see:');
    for (const g of result.skillGaps.slice(0, 20)) lines.push(`${markdown ? '- ' : '  '}${g.skill}: not in ${g.missing.join(', ')}`);
    if (result.skillGaps.length > 20) lines.push(`${markdown ? '- ' : '  '}... and ${result.skillGaps.length - 20} more`);
  }
  if (result.conflicts.length) {
    lines.push('');
    lines.push('Same skill name, different content (which copy a CLI uses depends on folder order):');
    for (const c of result.conflicts) lines.push(`${markdown ? '- ' : '  '}${c.skill}: ${c.copies.map((x) => `${x.folder} (${x.hash})`).join(' vs ')}`);
  }
  return lines.join('\n');
}

function main(argv) {
  const markdown = argv.includes('--markdown');
  const json = argv.includes('--json');
  const { home, aicmHome } = common.paths();
  const result = analyse(collect(home), home);
  common.writeState(aicmHome, 'config-drift', { finishedAt: new Date().toISOString(), ...result });
  if (json) { console.log(JSON.stringify(result, null, 2)); return 0; }
  console.log(render(result, markdown));
  const attention = result.conflicts.map((c) => `skill "${c.skill}" differs between ${c.copies.map((x) => x.folder).join(' and ')}`);
  for (const a of common.newSince(aicmHome, 'config-drift-attention', attention)) console.log(`attention: ${a}`);
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = { codexMcp, collect, analyse, render, commandExists };
