#!/usr/bin/env node
// Per-CLI update policies, shared by the macOS/Linux and Windows updaters.
//
//   node update-policy.js load --file <policy.json> --ids <id,id,...> --global-age <days>
//       Validates $AICM_HOME/update-policy.json and prints the normalized result as tab fields:
//         schema<TAB>1
//         fingerprint<TAB><sha256 of normalized policy + global age baseline>
//         rule<TAB><id><TAB><exclude 0|1><TAB><pin|-><TAB><explicit age|-><TAB><effective age>
//
//   node update-policy.js pin-check --file <npm-view.json> --pin <version> [--age <days>]
//                                  [--amp] [--deprecated <text>]
//       Checks that an exact pin is published, old enough and not deprecated. Prints "ok" and exits 0,
//       or prints "error: <reason>" and exits 1. The "latest" dist-tag is deliberately not consulted:
//       an older pin is valid.
//
// No third-party dependencies: this must run wherever Node.js exists, including old Node versions.
'use strict';

const fs = require('fs');
const crypto = require('crypto');

const ROOT_FIELDS = new Set(['schemaVersion', 'tools']);
const TOOL_FIELDS = new Set(['exclude', 'pin', 'minReleaseAgeDays']);
// Null prototype: ids like "constructor" or "toString" must stay ordinary custom catalog ids.
const ALIASES = Object.freeze(Object.assign(Object.create(null), { gpt: 'codex' }));
const STABLE_PIN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const AMP_PIN = /^0\.0\.(\d{10})-g[0-9a-f]{6,40}$/i;

class PolicyError extends Error {}

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readJsonFile(file) {
  let text;
  try {
    text = stripBom(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    throw new PolicyError(`cannot read ${file}: ${err.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new PolicyError(`invalid JSON: ${err.message}`);
  }
}

function hasAlias(key) {
  return Object.prototype.hasOwnProperty.call(ALIASES, key);
}

function canonicalId(id) {
  return hasAlias(id) ? ALIASES[id] : id;
}

function isStablePin(value) {
  return typeof value === 'string' && STABLE_PIN.test(value);
}

function isAmpPin(value) {
  return typeof value === 'string' && AMP_PIN.test(value);
}

// A pin must be an exact stable release (or Amp's timestamp-hash release on the Amp packages).
// Ranges, tags, URLs, files, prereleases and anything with shell metacharacters are refused.
function validPinFor(id, pin) {
  if (isStablePin(pin)) return true;
  return id === 'amp' && isAmpPin(pin);
}

function normalizePolicy(raw, catalogIds) {
  if (!isPlainObject(raw)) throw new PolicyError('policy must be a JSON object');
  for (const key of Object.keys(raw)) {
    if (!ROOT_FIELDS.has(key)) throw new PolicyError(`unknown field "${key}"`);
  }
  if (raw.schemaVersion !== 1) throw new PolicyError('schemaVersion must be the number 1');
  if (!isPlainObject(raw.tools)) throw new PolicyError('tools must be a JSON object');

  const known = new Set((catalogIds || []).map(String));
  const normalized = {};
  const seen = new Set();
  for (const key of Object.keys(raw.tools)) {
    const id = canonicalId(key);
    if (hasAlias(key) && Object.prototype.hasOwnProperty.call(raw.tools, id)) {
      throw new PolicyError(`tool "${key}" is an alias of "${id}"; do not configure both`);
    }
    if (!known.has(id)) throw new PolicyError(`unknown CLI id "${key}"`);
    if (seen.has(id)) throw new PolicyError(`CLI "${id}" is configured more than once`);
    seen.add(id);

    const rule = raw.tools[key];
    if (!isPlainObject(rule)) throw new PolicyError(`tools.${key} must be a JSON object`);
    for (const field of Object.keys(rule)) {
      if (!TOOL_FIELDS.has(field)) throw new PolicyError(`unknown field "tools.${key}.${field}"`);
    }
    const out = {};
    if (Object.prototype.hasOwnProperty.call(rule, 'exclude')) {
      if (typeof rule.exclude !== 'boolean') throw new PolicyError(`tools.${key}.exclude must be true or false`);
      out.exclude = rule.exclude;
    }
    if (Object.prototype.hasOwnProperty.call(rule, 'minReleaseAgeDays')) {
      const age = rule.minReleaseAgeDays;
      if (!Number.isInteger(age) || age < 0 || age > 3650) {
        throw new PolicyError(`tools.${key}.minReleaseAgeDays must be an integer from 0 to 3650`);
      }
      out.minReleaseAgeDays = age;
    }
    if (Object.prototype.hasOwnProperty.call(rule, 'pin')) {
      if (typeof rule.pin !== 'string' || !validPinFor(id, rule.pin)) {
        throw new PolicyError(`tools.${key}.pin must be an exact stable version (or Amp's timestamp-hash version)`);
      }
      out.pin = rule.pin;
    }
    normalized[id] = out;
  }

  const sorted = {};
  for (const id of Object.keys(normalized).sort()) sorted[id] = normalized[id];
  return { schemaVersion: 1, tools: sorted };
}

function fingerprint(normalized, globalAgeDays) {
  const age = Number.isInteger(globalAgeDays) && globalAgeDays >= 0 ? globalAgeDays : 0;
  const tools = {};
  for (const id of Object.keys(normalized.tools || {}).sort()) {
    const rule = normalized.tools[id] || {};
    const out = {};
    if (rule.exclude !== undefined) out.exclude = rule.exclude;
    if (rule.minReleaseAgeDays !== undefined) out.minReleaseAgeDays = rule.minReleaseAgeDays;
    if (rule.pin !== undefined) out.pin = rule.pin;
    tools[id] = out;
  }
  const text = JSON.stringify({ schemaVersion: 1, globalAgeDays: age, tools });
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

// Numeric components stay strings: an absurdly long version must not lose digits to Number rounding.
function parseVersion(version, amp) {
  const text = String(version || '');
  let m = STABLE_PIN.exec(text);
  if (m) return { nums: [m[1], m[2], m[3]], amp: false, raw: text };
  if (amp) {
    m = AMP_PIN.exec(text);
    if (m) return { nums: ['0', '0', m[1]], amp: true, raw: text };
  }
  return null;
}

function compareNumericStrings(a, b) {
  // Amp's timestamp form permits leading zeros; stable versions do not.
  a = a.replace(/^0+(?=\d)/, '');
  b = b.replace(/^0+(?=\d)/, '');
  if (a.length !== b.length) return a.length < b.length ? -1 : 1;
  if (a === b) return 0;
  return a < b ? -1 : 1;
}

function compareVersions(a, b, amp) {
  const pa = parseVersion(a, amp);
  const pb = parseVersion(b, amp);
  if (!pa || !pb) return null;
  for (let i = 0; i < 3; i++) {
    const cmp = compareNumericStrings(pa.nums[i], pb.nums[i]);
    if (cmp !== 0) return cmp;
  }
  return 0;
}

// Only the versions list proves a release is still published. `time` keeps unpublished versions,
// so it must never stand in for the list: an exact pin would otherwise install a withdrawn release.
function listedVersions(view) {
  if (Array.isArray(view.versions)) return new Set(view.versions.map(String));
  if (typeof view.versions === 'string') return new Set([view.versions]);
  return new Set();
}

function evaluatePin(view, pin, minAgeDays, options) {
  const opts = options || {};
  const amp = Boolean(opts.amp);
  const now = Number.isFinite(opts.now) ? opts.now : Date.now();
  const age = Number.isInteger(minAgeDays) ? minAgeDays : 0;
  if (!validPinFor(opts.id || (amp ? 'amp' : ''), pin)) {
    return { ok: false, reason: `"${pin}" is not an exact stable version` };
  }
  const listed = listedVersions(view || {});
  if (!listed.has(pin)) return { ok: false, reason: `pinned version ${pin} is not published` };
  const published = Date.parse(((view || {}).time || {})[pin]);
  if (!Number.isFinite(published)) return { ok: false, reason: `pinned version ${pin} has no publish date` };
  // A clock-skewed future date is never old enough, not even when minReleaseAgeDays is 0.
  if (published > now) return { ok: false, reason: `pinned version ${pin} has a publish date in the future` };
  if (age > 0 && published > now - age * 86400000) {
    return { ok: false, reason: `pinned version ${pin} is younger than ${age} days` };
  }
  const deprecated = typeof opts.deprecated === 'string' ? opts.deprecated.trim() : '';
  if (deprecated) return { ok: false, reason: `pinned version ${pin} is deprecated (${deprecated})` };
  return { ok: true, published };
}

function readView(file) {
  const value = readJsonFile(file);
  return Array.isArray(value) ? value[value.length - 1] || {} : value;
}

function parseOptions(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) throw new PolicyError(`unexpected argument "${arg}"`);
    const name = arg.slice(2);
    if (name === 'amp') { opts.amp = true; continue; }
    const value = argv[++i];
    if (value === undefined) throw new PolicyError(`missing value for --${name}`);
    opts[name] = value;
  }
  return opts;
}

function loadCommand(opts) {
  if (!opts.file) throw new PolicyError('--file is required');
  const ids = String(opts.ids || '').split(',').map((s) => s.trim()).filter(Boolean);
  const globalAge = Number(opts['global-age'] || 0);
  const policy = normalizePolicy(readJsonFile(opts.file), ids);
  const fp = fingerprint(policy, globalAge);
  const lines = ['schema\t1', `fingerprint\t${fp}`];
  for (const id of Object.keys(policy.tools)) {
    const rule = policy.tools[id];
    const pin = rule.pin === undefined ? '-' : rule.pin;
    const explicitAge = rule.minReleaseAgeDays === undefined ? '-' : String(rule.minReleaseAgeDays);
    const effectiveAge = rule.minReleaseAgeDays === undefined ? String(Number.isInteger(globalAge) ? globalAge : 0) : String(rule.minReleaseAgeDays);
    lines.push(['rule', id, rule.exclude ? '1' : '0', pin, explicitAge, effectiveAge].join('\t'));
  }
  process.stdout.write(lines.join('\n') + '\n');
}

function pinCheckCommand(opts) {
  if (!opts.file) throw new PolicyError('--file is required');
  if (!opts.pin) throw new PolicyError('--pin is required');
  const result = evaluatePin(readView(opts.file), String(opts.pin), Number(opts.age || 0), {
    amp: Boolean(opts.amp),
    deprecated: opts.deprecated || '',
  });
  if (result.ok) {
    process.stdout.write('ok\n');
    return 0;
  }
  process.stdout.write(`error: ${result.reason}\n`);
  return 1;
}

function main(argv) {
  const [mode] = argv;
  const opts = parseOptions(argv.slice(1));
  if (mode === 'load') { loadCommand(opts); return 0; }
  if (mode === 'pin-check') return pinCheckCommand(opts);
  process.stderr.write('usage: update-policy.js load --file <policy> --ids <ids> --global-age <days>\n' +
    '       update-policy.js pin-check --file <view.json> --pin <version> [--age <days>] [--amp] [--deprecated <text>]\n');
  return 2;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (err) {
    if (err instanceof PolicyError) {
      process.stderr.write(`update-policy: ${err.message}\n`);
    } else {
      process.stderr.write(`update-policy: ${err && err.message ? err.message : err}\n`);
    }
    process.exitCode = err instanceof PolicyError ? 2 : 1;
  }
}

module.exports = {
  PolicyError,
  canonicalId,
  isAmpPin,
  isStablePin,
  validPinFor,
  normalizePolicy,
  fingerprint,
  parseVersion,
  compareVersions,
  evaluatePin,
};
