// Shared helpers for the Node.js parts of AI CLI Auto Manager (worktrees, config drift, processes).
'use strict';

const fs = require('fs');
const path = require('path');

function paths() {
  const home = (process.platform === 'win32' ? process.env.USERPROFILE : process.env.HOME) || require('os').homedir();
  const aicmHome = process.env.AICM_HOME || path.join(home, '.ai-cli-auto-manager');
  return { home, aicmHome };
}

function display(p, home) {
  const norm = (s) => path.resolve(s).replace(/\\/g, '/');
  const a = norm(p);
  const h = norm(home);
  return a.toLowerCase().startsWith(h.toLowerCase() + '/') ? '~' + a.slice(h.length) : a;
}

function writeState(aicmHome, name, value) {
  const dir = path.join(aicmHome, 'state');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(value, null, 2));
}

function readState(aicmHome, name) {
  try { return JSON.parse(fs.readFileSync(path.join(aicmHome, 'state', `${name}.json`), 'utf8')); } catch { return null; }
}

// Items not seen in the previous run (so a lasting problem is announced once); remembers the current list.
function newSince(aicmHome, key, items) {
  const before = new Set((readState(aicmHome, key) || {}).items || []);
  writeState(aicmHome, key, { items });
  return items.filter((i) => !before.has(i));
}

function readJson(file) {
  const text = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
  try { return JSON.parse(text); } catch { /* fall through: JSON with comments */ }
  // Strip // and /* */ comments outside strings, then trailing commas (settings files sometimes have them).
  let out = '';
  let inStr = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      out += c;
      if (c === '\\') { out += text[++i] || ''; } else if (c === '"') inStr = false;
    } else if (c === '"') { inStr = true; out += c; }
    else if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; out += '\n'; }
    else if (c === '/' && text[i + 1] === '*') { i += 2; while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++; i++; }
    else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, '$1'));
}

module.exports = { paths, display, writeState, readState, newSince, readJson };
