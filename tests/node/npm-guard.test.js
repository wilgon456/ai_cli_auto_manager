// Tests for lib/npm-guard.js: which release the daily update may install, and the red-flag compare.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'npm-guard.js');
const { candidatesOf, redFlags } = require(MODULE);
const NOW = Date.parse('2026-10-07T00:00:00Z');
const daysAgo = (n) => new Date(NOW - n * 86400000).toISOString();

const view = {
  time: {
    created: daysAgo(400), modified: daysAgo(0),
    '1.0.0': daysAgo(60), '1.1.0': daysAgo(30), '1.2.0': daysAgo(20),
    '1.3.0': daysAgo(10), // unpublished: still in `time`, gone from `versions`
    '1.4.0-beta.1': daysAgo(9), '1.4.0': daysAgo(2), '2.0.0': daysAgo(40),
  },
  'dist-tags': { latest: '1.4.0', next: '2.0.0' },
  versions: ['1.0.0', '1.1.0', '1.2.0', '1.4.0-beta.1', '1.4.0', '2.0.0'],
};

test('unpublished versions are never picked', () => {
  assert.deepStrictEqual(candidatesOf(view, 3, NOW), ['1.2.0', '1.1.0', '1.0.0']);
});

test('waiting period, prereleases and versions above latest', () => {
  assert.deepStrictEqual(candidatesOf(view, 0, NOW), ['1.4.0', '1.2.0', '1.1.0', '1.0.0'], '2.0.0 is above latest, the beta is a prerelease');
  assert.deepStrictEqual(candidatesOf(view, 25, NOW), ['1.1.0', '1.0.0']);
  assert.deepStrictEqual(candidatesOf(view, 100, NOW), []);
});

test('a single version is printed by npm as a string', () => {
  const one = { time: { '1.0.0': daysAgo(10), '0.9.0': daysAgo(20) }, 'dist-tags': { latest: '1.0.0' }, versions: '1.0.0' };
  assert.deepStrictEqual(candidatesOf(one, 3, NOW), ['1.0.0']);
});

test('without a versions field every version in time counts (older callers)', () => {
  const old = { time: { '1.0.0': daysAgo(10), '1.1.0': daysAgo(5) }, 'dist-tags': { latest: '1.1.0' } };
  assert.deepStrictEqual(candidatesOf(old, 3, NOW), ['1.1.0', '1.0.0']);
});

test('command line: pick and candidates read the npm view file', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-guard-'));
  try {
    const file = path.join(dir, 'view.json');
    const live = { ...view, time: { ...view.time } };
    // Real dates around now, so the CLI (which uses the clock) sees the same picture.
    for (const k of Object.keys(live.time)) live.time[k] = new Date(Date.now() - (NOW - Date.parse(view.time[k]))).toISOString();
    fs.writeFileSync(file, JSON.stringify(live));
    const pick = spawnSync(process.execPath, [MODULE, 'pick', '3', file], { encoding: 'utf8' });
    assert.strictEqual(pick.status, 0, pick.stderr);
    assert.strictEqual(pick.stdout.trim(), '1.2.0');
    const all = spawnSync(process.execPath, [MODULE, 'candidates', '3', file], { encoding: 'utf8' });
    assert.deepStrictEqual(all.stdout.trim().split(/\r?\n/), ['1.2.0', '1.1.0', '1.0.0']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Amp git-describe stable train is kept; betas and versions above latest are not', () => {
  const amp = {
    name: '@ampcode/cli',
    time: {
      created: daysAgo(400), modified: daysAgo(0),
      '0.0.1792700000-gabc123': daysAgo(10),
      '0.0.1792800065-ga5b55b': daysAgo(2),
      '0.0.1792600000-beta.1': daysAgo(12),
      '0.0.1792900000-gffff': daysAgo(10),
      '0.0.1792500000-gaaaaaa': daysAgo(20),
    },
    'dist-tags': { latest: '0.0.1792800065-ga5b55b' },
    versions: [
      '0.0.1792500000-gaaaaaa',
      '0.0.1792600000-beta.1',
      '0.0.1792700000-gabc123',
      '0.0.1792800065-ga5b55b',
      '0.0.1792900000-gffff',
    ],
  };
  assert.deepStrictEqual(candidatesOf(amp, 3, NOW), ['0.0.1792700000-gabc123', '0.0.1792500000-gaaaaaa']);
  assert.deepStrictEqual(candidatesOf(amp, 0, NOW), ['0.0.1792800065-ga5b55b', '0.0.1792700000-gabc123', '0.0.1792500000-gaaaaaa']);
  assert.deepStrictEqual(candidatesOf({ ...amp, name: '@sourcegraph/amp' }, 3, NOW), ['0.0.1792700000-gabc123', '0.0.1792500000-gaaaaaa']);
  assert.deepStrictEqual(candidatesOf({ ...amp, name: 'unrelated-package' }, 0, NOW), [], 'the exception is limited to Amp');
  assert.deepStrictEqual(candidatesOf({ ...amp, name: undefined }, 0, NOW), [], 'unknown callers keep rejecting prereleases');
});

test('git suffixes on ordinary semver and ambiguous Amp timestamps remain excluded', () => {
  const versions = ['1.2.3-gabcdef', '0.0.1792800065-g111111', '0.0.1792800065-ga5b55b'];
  const data = { name: '@ampcode/cli', versions, time: Object.fromEntries(versions.map((v) => [v, daysAgo(10)])),
    'dist-tags': { latest: '0.0.1792800065-ga5b55b' } };
  assert.deepStrictEqual(candidatesOf(data, 3, NOW), ['0.0.1792800065-ga5b55b']);
});

test('red flags: lost provenance and new install scripts', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-guard-'));
  try {
    const a = path.join(dir, 'a.json');
    const b = path.join(dir, 'b.json');
    fs.writeFileSync(a, JSON.stringify({ version: '1.0.0', dist: { attestations: { provenance: {} } }, scripts: {} }));
    fs.writeFileSync(b, JSON.stringify({ version: '1.1.0', dist: {}, scripts: { postinstall: 'node x.js' } }));
    const flags = redFlags(a, b);
    assert.strictEqual(flags.length, 2);
    assert.match(flags[0], /^provenance:/);
    assert.match(flags[1], /^install script: 1\.1\.0 adds "postinstall"/);
    assert.deepStrictEqual(redFlags(a, a), []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
