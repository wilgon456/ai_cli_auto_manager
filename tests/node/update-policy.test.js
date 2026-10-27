// Tests for lib/update-policy.js: validation, BOM, aliases, fingerprints and exact-pin checks.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const MODULE = path.join(__dirname, '..', '..', 'lib', 'update-policy.js');
const {
  PolicyError, canonicalId, normalizePolicy, fingerprint, evaluatePin, compareVersions, validPinFor,
} = require(MODULE);

const IDS = ['claude', 'codex', 'opencode', 'grok', 'kimi', 'agy', 'amp', 'local-tool', 'constructor', 'toString'];
const NOW = Date.parse('2026-10-24T00:00:00Z');
const daysAgo = (n) => new Date(NOW - n * 86400000).toISOString();

function policy(tools, extra) {
  return Object.assign({ schemaVersion: 1, tools }, extra || {});
}

function view(versions, latest) {
  const time = { created: daysAgo(400), modified: daysAgo(0) };
  for (const [version, age] of versions) time[version] = daysAgo(age);
  return { time, 'dist-tags': { latest: latest || versions[0][0] }, versions: versions.map((v) => v[0]) };
}

test('valid policy is normalized, sorted, and aliases gpt to codex', () => {
  const out = normalizePolicy(policy({ grok: { exclude: true }, gpt: { pin: '1.2.3', minReleaseAgeDays: 7 } }), IDS);
  assert.deepStrictEqual(Object.keys(out.tools), ['codex', 'grok']);
  assert.deepStrictEqual(out.tools.codex, { pin: '1.2.3', minReleaseAgeDays: 7 });
  assert.deepStrictEqual(out.tools.grok, { exclude: true });
});

test('custom local catalog ids are accepted', () => {
  const out = normalizePolicy(policy({ 'local-tool': { pin: '0.1.0' } }), IDS);
  assert.strictEqual(out.tools['local-tool'].pin, '0.1.0');
});

test('prototype property names stay ordinary custom ids', () => {
  const out = normalizePolicy(policy({ constructor: { exclude: true }, toString: { pin: '1.0.0' } }), IDS);
  assert.deepStrictEqual(Object.keys(out.tools), ['constructor', 'toString']);
  assert.deepStrictEqual(out.tools.constructor, { exclude: true });
  assert.deepStrictEqual(out.tools.toString, { pin: '1.0.0' });
  assert.strictEqual(canonicalId('constructor'), 'constructor');
  assert.strictEqual(canonicalId('toString'), 'toString');
});

test('unknown root/tool fields, wrong types, unknown ids and alias collisions are rejected', () => {
  const cases = [
    [policy({}, { extra: 1 }), /unknown field "extra"/],
    [policy({ codex: { exlude: true } }), /unknown field "tools\.codex\.exlude"/],
    [policy({ codex: { exclude: 'yes' } }), /exclude must be true or false/],
    [policy({ codex: { minReleaseAgeDays: 1.5 } }), /integer from 0 to 3650/],
    [policy({ codex: { minReleaseAgeDays: 3651 } }), /integer from 0 to 3650/],
    [policy({ nope: { exclude: true } }), /unknown CLI id "nope"/],
    [policy({ gpt: {}, codex: {} }), /alias of "codex"/],
    [{ schemaVersion: '1', tools: {} }, /schemaVersion must be the number 1/],
    [{ schemaVersion: 1, tools: [] }, /tools must be a JSON object/],
  ];
  for (const [doc, pattern] of cases) assert.throws(() => normalizePolicy(doc, IDS), pattern);
});

test('pins must be exact stable versions or the Amp timestamp-hash form', () => {
  for (const pin of ['1.2.3', '0.0.1792800065-ga5b55b']) {
    assert.strictEqual(validPinFor('amp', pin), true, pin);
  }
  for (const pin of ['^1.2.3', '~1.2.3', '1.2', '1.2.3-beta.1', 'latest', 'https://x/y.tgz', '1.2.3; rm -rf /', '$(id)', 'v1.2.3', '']) {
    assert.throws(() => normalizePolicy(policy({ codex: { pin } }), IDS), /exact stable version/, pin);
  }
  assert.strictEqual(validPinFor('codex', '0.0.1792800065-ga5b55b'), false, 'Amp form is only for Amp');
});

test('UTF-8 BOM is accepted on read', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'update-policy-'));
  try {
    const file = path.join(dir, 'update-policy.json');
    fs.writeFileSync(file, '\uFEFF' + JSON.stringify(policy({ codex: { exclude: true } })));
    const load = spawnSync(process.execPath, [MODULE, 'load', '--file', file, '--ids', IDS.join(','), '--global-age', '3'], { encoding: 'utf8' });
    assert.strictEqual(load.status, 0, load.stderr);
    assert.match(load.stdout, /^schema\t1$/m);
    assert.match(load.stdout, /^rule\tcodex\t1\t-\t-\t3$/m);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('fingerprint is stable and changes with policy, alias spelling, or global age', () => {
  const a = normalizePolicy(policy({ codex: { pin: '1.2.3', minReleaseAgeDays: 7 } }), IDS);
  const same = normalizePolicy(policy({ gpt: { minReleaseAgeDays: 7, pin: '1.2.3' } }), IDS);
  assert.strictEqual(fingerprint(a, 3), fingerprint(same, 3));
  assert.notStrictEqual(fingerprint(a, 3), fingerprint(a, 5));
  const changed = normalizePolicy(policy({ codex: { pin: '1.2.4', minReleaseAgeDays: 7 } }), IDS);
  assert.notStrictEqual(fingerprint(a, 3), fingerprint(changed, 3));
});

test('exact pin checks: published, age, deprecated, and latest is deliberately ignored', () => {
  const data = view([['1.2.3', 30], ['2.0.0', 5]], '2.0.0');
  assert.strictEqual(evaluatePin(data, '1.2.3', 7, { now: NOW }).ok, true, 'older-than-latest pin is valid');
  assert.match(evaluatePin(data, '1.2.3', 45, { now: NOW }).reason, /younger than 45 days/);
  assert.match(evaluatePin(data, '9.9.9', 0, { now: NOW }).reason, /not published/);
  assert.match(evaluatePin(data, '2.0.0', 0, { now: NOW, deprecated: 'use 3.x' }).reason, /deprecated/);
  assert.strictEqual(evaluatePin(data, '1.2.3', 0, { now: NOW, id: 'amp' }).ok, true, 'plain stable pins are fine for Amp too');
});

test('future publish dates are rejected even with no minimum age', () => {
  const future = { time: { '1.2.3': new Date(NOW + 86400000).toISOString() }, versions: ['1.2.3'] };
  assert.match(evaluatePin(future, '1.2.3', 0, { now: NOW }).reason, /future/);
});

test('a missing versions field never treats stale time entries as published', () => {
  const stale = { time: { '1.2.3': daysAgo(30), created: daysAgo(400), modified: daysAgo(0) } };
  assert.match(evaluatePin(stale, '1.2.3', 0, { now: NOW }).reason, /not published/);
});

test('Amp timestamp-hash pins are accepted only for Amp, and equal timestamps cannot be ordered', () => {
  const amp = { name: '@ampcode/cli', time: { '0.0.1792800065-ga5b55b': daysAgo(10) }, versions: ['0.0.1792800065-ga5b55b'] };
  assert.strictEqual(evaluatePin(amp, '0.0.1792800065-ga5b55b', 7, { now: NOW, amp: true }).ok, true);
  assert.match(evaluatePin(amp, '0.0.1792800065-ga5b55b', 7, { now: NOW }).reason, /not published|exact/);
  const sameBase = { time: { '0.0.1792800065-gabcdef': daysAgo(10) }, versions: ['0.0.1792800065-gabcdef'] };
  assert.match(evaluatePin(sameBase, '0.0.1792800065-g111111', 0, { now: NOW, amp: true }).reason, /not published/);
});

test('version comparison supports downgrade decisions', () => {
  assert.strictEqual(compareVersions('1.2.3', '2.0.0'), -1);
  assert.strictEqual(compareVersions('2.0.0', '1.2.3'), 1);
  assert.strictEqual(compareVersions('1.2.3', '1.2.3'), 0);
  assert.strictEqual(compareVersions('1.2.3-beta.1', '1.2.3'), null, 'pins are stable only');
  assert.strictEqual(compareVersions('0.0.1792800065-ga5b55b', '0.0.1792700000-gabc123', true), 1);
});

test('huge numeric version components do not round in ordering decisions', () => {
  assert.strictEqual(compareVersions('1.0.9007199254740993', '1.0.9007199254740992'), 1);
  assert.strictEqual(compareVersions('1.0.9007199254740992', '1.0.9007199254740993'), -1);
  assert.strictEqual(compareVersions('123456789012345678901.0.0', '123456789012345678900.0.0'), 1);
  assert.strictEqual(compareVersions('0.0.1792800065-gabc123', '0.0.1792800065-gabc124', true), 0);
});

test('malformed files fail without evaluating content', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'update-policy-'));
  try {
    const file = path.join(dir, 'update-policy.json');
    fs.writeFileSync(file, '{"schemaVersion":1,"tools":{"codex":{"pin":"1.2.3"}}');
    const load = spawnSync(process.execPath, [MODULE, 'load', '--file', file, '--ids', IDS.join(','), '--global-age', '3'], { encoding: 'utf8' });
    assert.notStrictEqual(load.status, 0);
    assert.match(load.stderr, /invalid JSON/);
    assert.ok(load.stdout === undefined || load.stdout === '', 'no normalized output for an invalid file');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('PolicyError is used for policy problems', () => {
  assert.throws(() => normalizePolicy(null, IDS), PolicyError);
});
