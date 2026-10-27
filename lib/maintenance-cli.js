#!/usr/bin/env node
'use strict';
// User-facing adapter for archive list, restore and history.
// Requires the maintenance.js API. Does not move files itself.
const path = require('path');

let api;
try {
  api = require('./maintenance.js');
} catch (e) {
  console.error('lib/maintenance.js is missing from this copy');
  process.exit(1);
}

function need(name) {
  if (typeof api[name] !== 'function') {
    console.error(`lib/maintenance.js does not export ${name}`);
    process.exit(1);
  }
}

function parseFlags(cmd, argv) {
  const out = { _: [], json: false, dryRun: false, limit: null, offset: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json' || a === '-Json') out.json = true;
    else if (a === '--dry-run' || a === '-DryRun') out.dryRun = true;
    else if (a === '--limit' || a === '-Limit' || a === '--offset' || a === '-Offset') {
      const v = argv[++i];
      const key = a.toLowerCase().includes('limit') ? 'limit' : 'offset';
      if (v == null || !/^\d{1,9}$/.test(v)) {
        console.error(cmd === 'history' ? 'history: limit must be an integer from 1 to 100' : `${cmd}: ${key} must be a whole number`);
        process.exit(2);
      }
      out[key] = Number(v);
    } else if (a === '--') continue;
    else if (a.startsWith('-')) {
      console.error(`unknown argument: ${a}`);
      process.exit(2);
    } else out._.push(a);
  }
  return out;
}

function asciiJson(value) {
  return JSON.stringify(value).replace(/[^\x00-\x7f]/g, (ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
}

function printList(result, json) {
  if (json) { console.log(asciiJson(result)); return; }
  for (const item of result.items || []) {
    if (item.status === 'legacy') console.log(`legacy - ${item.stored} manual restore (not a generic archive id)`);
    else if (item.native === 'codex' || item.codex) console.log(`codex-native ${item.id || '-'} ${item.stored || ''} (use Codex, not aicm restore)`);
    else console.log(`${item.status} ${item.id} ${item.stored}`);
  }
  for (const p of result.problems || []) console.log(`problem ${p.file} ${p.error}`);
  if (result.index && result.index.nextOffset != null) {
    console.log(`more: ${result.index.total - result.index.nextOffset} older index records; next page: aicm archive list --offset ${result.index.nextOffset}`);
  }
}

function recordRestore(result, requestedId) {
  if (result.dryRun) return;
  need('historyAdd');
  const summary = { restored: result.ok ? 1 : 0, errors: result.ok ? 0 : 1, conflicts: result.status === 'conflict' ? 1 : 0 };
  const row = {
    action: result.ok ? 'restored' : (result.status === 'conflict' ? 'conflict' : 'error'),
    status: result.ok ? 'restored' : (result.status === 'conflict' ? 'conflict' : 'error'),
    id: result.id || requestedId,
    path: result.original || result.stored,
    bytes: Number.isInteger(result.size) ? result.size : undefined,
  };
  try {
    const added = api.historyAdd('restore', { ok: result.ok === true, summary, results: [row] }, { dryRun: false });
    if (!added || added.ok === false) console.error(`warning: history was not recorded: ${(added && added.error) || 'history-add failed'}`);
  } catch (e) {
    console.error(`warning: history was not recorded: ${e.message || e}`);
  }
}

function historyLine(item) {
  const summary = item.summary || {};
  const bits = [];
  if (item.kind === 'clean') {
    if (Number.isInteger(summary.freedBytes)) bits.push(`freed=${summary.freedBytes}`);
    if (Number.isInteger(summary.archivedBytes)) bits.push(`archived=${summary.archivedBytes}`);
  } else if (item.kind === 'update') {
    const counts = {};
    for (const row of item.results || []) {
      if (!row || typeof row.status !== 'string') continue;
      counts[row.status] = (counts[row.status] || 0) + 1;
    }
    for (const status of Object.keys(counts).sort()) bits.push(`${status}=${counts[status]}`);
  } else if (item.kind === 'restore') {
    if (Number.isInteger(summary.restored)) bits.push(`restored=${summary.restored}`);
    if (Number.isInteger(summary.conflicts)) bits.push(`conflict=${summary.conflicts}`);
    if (Number.isInteger(summary.errors)) bits.push(`error=${summary.errors}`);
  }
  return [item.finishedAt, item.kind, item.id].concat(bits).join(' ');
}

function main(argv) {
  const cmd = argv[0];
  const args = parseFlags(cmd, argv.slice(1));
  if (cmd === 'archive') {
    const sub = args._[0] || 'list';
    if (!['list', 'gc'].includes(sub) || args._.length > 1) {
      console.error('usage: aicm archive list [--json] [--limit N] [--offset N] | aicm archive gc [--dry-run] [--json]');
      return 2;
    }
    if (sub === 'gc') {
      if (args.limit != null || args.offset != null) {
        console.error('usage: aicm archive gc [--dry-run] [--json]');
        return 2;
      }
      need('archiveGc');
      const result = api.archiveGc({ dryRun: args.dryRun });
      if (args.json) console.log(asciiJson(result));
      else if (!result.ok) console.error(`archive gc: ${result.error}`);
      else {
        console.log(`archive index: ${result.dryRun ? 'would drop' : 'dropped'} ${result.pruned} of ${result.total} records (${result.reasons.expired} expired, ${result.reasons.restored} restored more than 30 days ago)`);
        if (!result.complete) console.log('more records remain; run aicm archive gc again');
      }
      return result.ok ? 0 : 1;
    }
    if (args.dryRun) {
      console.error('usage: aicm archive list [--json] [--limit N] [--offset N]');
      return 2;
    }
    need('archiveList');
    const result = api.archiveList({ limit: args.limit == null ? undefined : args.limit, offset: args.offset == null ? undefined : args.offset });
    if (!result.ok) {
      if (args.json) console.log(asciiJson(result));
      else console.error(`archive list: ${result.error}`);
      return result.status === 'usage' ? 2 : 1;
    }
    printList(result, args.json);
    return 0;
  }
  if (cmd === 'restore') {
    if (args._.length !== 1) {
      console.error('usage: aicm restore ID [--dry-run] [--json]');
      return 2;
    }
    need('restore');
    const result = api.restore(args._[0], { dryRun: args.dryRun });
    if (!args.dryRun) recordRestore(result, args._[0]);
    if (args.json) console.log(asciiJson(result));
    else if (result.ok) console.log(`${result.dryRun ? 'would restore' : 'restored'} ${result.id} ${result.original}`);
    else if (result.status === 'legacy') console.error(`restore: ${result.error || 'legacy file; move it back by hand'}`);
    else console.error(`restore: ${result.error || 'failed'}`);
    return result.ok ? 0 : 1;
  }
  if (cmd === 'history') {
    if (args._.length || args.offset != null) {
      console.error('usage: aicm history [--limit N] [--json]');
      return 2;
    }
    need('historyList');
    const result = api.historyList({ limit: args.limit == null ? 20 : args.limit });
    if (!result.ok) {
      if (args.json) console.log(asciiJson(result));
      else console.error(`history: ${result.error}`);
      return result.status === 'usage' ? 2 : 1;
    }
    if (args.json) console.log(asciiJson(result));
    else {
      for (const item of result.items || []) console.log(historyLine(item));
      for (const p of result.problems || []) console.log(`malformed ${p.file}`);
    }
    return 0;
  }
  console.error('usage: archive list | restore ID | history');
  return 2;
}

if (require.main === module) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (e) { console.error(e.message || String(e)); process.exitCode = 1; }
}

module.exports = { main };
