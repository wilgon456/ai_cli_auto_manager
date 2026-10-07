#!/usr/bin/env node
// Fake npm for the tests (Windows and macOS/Linux). Never touches the network or the real npm.
//
//   FAKE_NPM_DIR     folder with registry.json; calls are appended to npm-calls.log there, and the
//                    --before value of every install to npm-before.log
//   FAKE_NPM_PREFIX  what `npm prefix -g` prints
//   FAKE_NPM_ROOT    global node_modules folder (`npm root -g`)
//   FAKE_NPM_OFFLINE 1: the registry cannot be reached
//   FAKE_NPM_WARN    1: every call prints a warning on stderr, like npm with an old .npmrc setting
//
// registry.json: { "<pkg>": { "latest": "1.2.0", "versions": { "1.0.0": { "daysAgo": 30,
//   "provenance": true, "scripts": { "postinstall": "..." }, "badsig": false, "nokeys": false,
//   "ebusy": false, "unpublished": false, "deprecated": "message" } } } }
'use strict';

const fs = require('fs');
const path = require('path');

const dir = process.env.FAKE_NPM_DIR;
const prefix = process.env.FAKE_NPM_PREFIX;
const root = process.env.FAKE_NPM_ROOT;
const registry = JSON.parse(fs.readFileSync(path.join(dir, 'registry.json'), 'utf8'));
const args = process.argv.slice(2);
const log = (line) => fs.appendFileSync(path.join(dir, 'npm-calls.log'), line + '\n');

// Positional arguments, skipping flags and the value of --prefix.
const positional = [];
for (let i = 1; i < args.length; i++) {
  if (args[i] === '--prefix') { i++; continue; }
  if (!args[i].startsWith('-')) positional.push(args[i]);
}
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const before = (args.find((a) => a.startsWith('--before=')) || '').slice('--before='.length);

function split(spec) {
  const at = spec.lastIndexOf('@');
  return at > 0 ? [spec.slice(0, at), spec.slice(at + 1)] : [spec, null];
}

const published = (info) => new Date(Date.now() - info.daysAgo * 86400000);

function manifest(name, version) {
  const v = registry[name].versions[version];
  const m = { name, version, scripts: v.scripts || {}, dist: {} };
  if (v.provenance) m.dist.attestations = { provenance: { predicateType: 'https://slsa.dev/provenance/v1' } };
  if (v.deprecated) m.deprecated = v.deprecated;
  return m;
}

function writePackage(nodeModules, name, version) {
  const d = path.join(nodeModules, ...name.split('/'));
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'package.json'), JSON.stringify({ name, version }, null, 2));
}

function listPackages(nodeModules) {
  const out = {};
  if (!fs.existsSync(nodeModules)) return out;
  for (const entry of fs.readdirSync(nodeModules)) {
    const dirs = entry.startsWith('@')
      ? fs.readdirSync(path.join(nodeModules, entry)).map((n) => `${entry}/${n}`)
      : [entry];
    for (const name of dirs) {
      const pj = path.join(nodeModules, ...name.split('/'), 'package.json');
      if (fs.existsSync(pj)) out[name] = JSON.parse(fs.readFileSync(pj, 'utf8')).version;
    }
  }
  return out;
}

function main() {
  if (process.env.FAKE_NPM_WARN === '1') {
    console.error('npm warn Unknown user config "always-auth". This will stop working in the next major version of npm.');
  }
  // FAKE_NPM_OFFLINE=1: the registry cannot be reached.
  if (process.env.FAKE_NPM_OFFLINE === '1' && ['ping', 'view', 'install'].includes(args[0]) && !args.includes('--prefix')) {
    console.error('npm error code ENOTFOUND\nnpm error request to https://registry.npmjs.org failed');
    return 1;
  }
  switch (args[0]) {
    case 'prefix': console.log(prefix); return 0;
    case 'root': console.log(root); return 0;
    case 'ls':
    case 'list': {
      const all = listPackages(root);
      const want = positional[0];
      if (args.includes('--json')) {
        const deps = {};
        for (const [n, v] of Object.entries(all)) if (!want || want === n) deps[n] = { version: v };
        console.log(JSON.stringify({ dependencies: deps }));
        return 0;
      }
      return want && !all[want] ? 1 : 0;
    }
    case 'view': {
      const [name, version] = split(positional[0]);
      const pkg = registry[name];
      if (!pkg) { console.error(`404 ${name}`); return 1; }
      const fields = positional.slice(1);
      if (version) {
        const info = pkg.versions[version];
        if (!info || info.unpublished) { console.error(`404 ${name}@${version}`); return 1; }
        const m = manifest(name, version);
        if (fields.length === 1) {
          const value = m[fields[0]];
          if (value !== undefined) console.log(args.includes('--json') ? JSON.stringify(value) : String(value));
        } else {
          console.log(JSON.stringify(m));
        }
        return 0;
      }
      if (fields.length === 1 && fields[0] === 'version') { console.log(pkg.latest); return 0; }
      // Like the real registry, `time` keeps unpublished versions; `versions` does not.
      const time = { created: new Date(0).toISOString(), modified: new Date().toISOString() };
      const versions = [];
      for (const [v, info] of Object.entries(pkg.versions)) {
        time[v] = published(info).toISOString();
        if (!info.unpublished) versions.push(v);
      }
      const out = { time, 'dist-tags': { latest: pkg.latest } };
      if (fields.includes('versions')) out.versions = versions;
      console.log(JSON.stringify(out));
      return 0;
    }
    case 'install': {
      let [name, version] = split(positional[0]);
      if (!version || version === 'latest') version = registry[name].latest;
      const stage = option('--prefix');
      const info = registry[name].versions[version];
      fs.appendFileSync(path.join(dir, 'npm-before.log'), `${stage ? 'stage' : 'install -g'} ${name}@${version} before=${before || 'none'}\n`);
      // Like npm: --before refuses a version published after that moment.
      if (before && info && published(info) > new Date(before)) {
        console.error(`npm error code ETARGET\nnpm error No matching version found for ${name}@${version} with a date before ${before}.`);
        return 1;
      }
      if (args.includes('-g')) {
        // "ebusy": a file of the installed copy is held by a running process (Windows).
        if (info && info.ebusy) {
          console.error("npm error code EBUSY\nnpm error EBUSY: resource busy or locked, copyfile 'cli.exe'");
          return 1;
        }
        writePackage(root, name, version);
        log(`install -g ${name}@${version}`);
      } else if (stage) {
        writePackage(path.join(stage, 'node_modules'), name, version);
        log(`stage ${name}@${version}${args.includes('--ignore-scripts') ? ' --ignore-scripts' : ''}`);
      }
      return 0;
    }
    case 'audit': {
      const staged = listPackages(path.join(option('--prefix'), 'node_modules'));
      for (const [n, v] of Object.entries(staged)) {
        const info = registry[n] && registry[n].versions[v];
        // "nokeys": a private registry (Verdaccio) that publishes no signing keys.
        if (info && info.nokeys) { console.error('npm error found no dependencies to audit that were installed from a supported registry'); return 1; }
        if (info && info.badsig) { console.error(`1 package has an invalid registry signature: ${n}@${v}`); return 1; }
      }
      console.log(`${Object.keys(staged).length} packages have verified registry signatures`);
      return 0;
    }
    default:
      return 0;
  }
}

process.exitCode = main();
