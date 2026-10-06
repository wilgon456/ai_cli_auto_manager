#!/usr/bin/env node
// Release checks for npm-managed CLIs, shared by the Windows and macOS/Linux updaters.
// Node is always present where npm is, so the logic lives here once.
//
//   node npm-guard.js pick <minAgeDays> <view.json>
//       view.json = output of `npm view <pkg> time dist-tags --json`
//       Prints the newest stable version that is at least <minAgeDays> old (and not newer than
//       the "latest" tag). Prints nothing when no version qualifies.
//
//   node npm-guard.js compare <installed.json> <candidate.json>
//       Each file = output of `npm view <pkg>@<version> --json`.
//       Prints one line per red flag; prints nothing when the candidate looks like the installed one:
//         - provenance: the installed version was published with a provenance attestation, the candidate was not
//         - install script: preinstall/install/postinstall appeared or changed
'use strict';

const fs = require('fs');

function readJson(file) {
  const text = fs.readFileSync(file, 'utf8').trim();
  if (!text) return {};
  const value = JSON.parse(text);
  // `npm view pkg@range --json` returns an array when several versions match; use the last one.
  return Array.isArray(value) ? value[value.length - 1] || {} : value;
}

function parse(version) {
  const m = /^(\d+)\.(\d+)\.(\d+)(-.+)?$/.exec(String(version || '').trim());
  return m ? { nums: [Number(m[1]), Number(m[2]), Number(m[3])], pre: m[4] || '' } : null;
}

function compare(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a.nums[i] !== b.nums[i]) return a.nums[i] - b.nums[i];
  }
  return 0;
}

function pick(minAgeDays, file, now = Date.now()) {
  const view = readJson(file);
  const times = view.time || {};
  const latest = parse((view['dist-tags'] || {}).latest);
  const cutoff = now - minAgeDays * 86400000;
  let best = null;
  let bestText = '';
  for (const [version, stamp] of Object.entries(times)) {
    if (version === 'created' || version === 'modified') continue;
    const v = parse(version);
    if (!v || v.pre) continue;
    if (latest && compare(v, latest) > 0) continue;
    const published = Date.parse(stamp);
    if (!Number.isFinite(published) || published > cutoff) continue;
    if (!best || compare(v, best) > 0) { best = v; bestText = version; }
  }
  return bestText;
}

const INSTALL_SCRIPTS = ['preinstall', 'install', 'postinstall'];

function redFlags(installedFile, candidateFile) {
  const installed = readJson(installedFile);
  const candidate = readJson(candidateFile);
  const flags = [];
  const prov = (m) => Boolean(m && m.dist && m.dist.attestations && m.dist.attestations.provenance);
  if (prov(installed) && !prov(candidate)) {
    flags.push(`provenance: ${installed.version} was published with a provenance attestation, ${candidate.version} was not`);
  }
  const before = installed.scripts || {};
  const after = candidate.scripts || {};
  for (const name of INSTALL_SCRIPTS) {
    if (after[name] && !before[name]) flags.push(`install script: ${candidate.version} adds "${name}": ${after[name]}`);
    else if (after[name] && before[name] && after[name] !== before[name]) flags.push(`install script: ${candidate.version} changes "${name}" to: ${after[name]}`);
  }
  return flags;
}

function main(argv) {
  const [mode, a, b] = argv;
  if (mode === 'pick') {
    const out = pick(Number(a), b);
    if (out) process.stdout.write(out + '\n');
    return 0;
  }
  if (mode === 'compare') {
    for (const line of redFlags(a, b)) process.stdout.write(line + '\n');
    return 0;
  }
  process.stderr.write('usage: npm-guard.js pick <days> <view.json> | compare <installed.json> <candidate.json>\n');
  return 2;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`npm-guard: ${err.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = { pick, redFlags, parse };
