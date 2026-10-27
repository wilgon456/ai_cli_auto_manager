// Independent regression checks added by the parent reviewer. Real user profiles are never used.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

function fixture(t) {
  const top = fs.mkdtempSync(path.join(os.tmpdir(), 'aicm-ownership-'));
  t.after(() => fs.rmSync(top, { recursive: true, force: true }));
  const home = path.join(top, 'home'); fs.mkdirSync(home);
  const manager = path.join(home, '.manager');
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('AICM_')));
  Object.assign(env, {HOME: home, USERPROFILE: home, AICM_HOME: manager, AICM_OS: 'linux', AICM_NOTIFY: '0'});
  return {top, home, manager, env};
}
function sync(fx) {
  return cp.spawnSync('/bin/bash', ['-c', '. "$1/lib/aicm-common.sh"; aicm_sync_app_copy "$1"', 'fixture', ROOT], {env: fx.env, encoding: 'utf8', timeout: 30000});
}
function put(file, text) {fs.mkdirSync(path.dirname(file), {recursive:true}); fs.writeFileSync(file, text);}

for (const subdir of ['lib', 'bin']) {
  test(`installed copy retains an unknown file nested under ${subdir}`, {skip: process.platform === 'win32'}, t => {
    const fx=fixture(t); const first=sync(fx); assert.equal(first.status, 0, first.stdout+first.stderr);
    const personal=path.join(fx.manager,'app',subdir,'personal-note.txt'); put(personal,'keep personal note');
    const again=sync(fx);
    assert.notEqual(again.status,0,'sync must refuse a copy containing an unmanaged nested file');
    assert.equal(fs.readFileSync(personal,'utf8'),'keep personal note');
  });
}

test('a dated archive shape cannot establish ownership of an unmarked home', {skip: process.platform === 'win32'}, t => {
  const fx=fixture(t); const personal=path.join(fx.manager,'archive','demo','20261027','personal.txt'); put(personal,'keep unrelated file');
  const result=sync(fx);
  assert.notEqual(result.status,0,'a rule/date folder shape is not ownership evidence');
  assert.ok(!fs.existsSync(path.join(fx.manager,'.aicm-home')),'unmanaged populated home must not be marked');
  assert.equal(fs.readFileSync(personal,'utf8'),'keep unrelated file');
});

test('purge keeps unindexed files even under a manager root and dated archive', {skip: process.platform === 'win32'}, t => {
  const fx=fixture(t); const first=sync(fx); assert.equal(first.status,0,first.stdout+first.stderr);
  const personal=path.join(fx.manager,'archive','demo','20261027','personal.txt'); put(personal,'keep unindexed archive');
  const cron=path.join(fx.top,'fake-crontab'); put(cron,'#!/bin/sh\nexit 0\n'); fs.chmodSync(cron,0o755);fx.env.AICM_CRONTAB=cron;
  const result=cp.spawnSync('/bin/bash',[path.join(ROOT,'bin/aicm'),'uninstall','--purge'],{env:fx.env,encoding:'utf8',timeout:30000});
  assert.equal(fs.readFileSync(personal,'utf8'),'keep unindexed archive',result.stdout+result.stderr);
});


test('a stale marker never makes the user profile root an install target', {skip: process.platform === 'win32'}, t => {
  const fx=fixture(t);fx.env.AICM_HOME=fx.home;
  put(path.join(fx.home,'.aicm-home'),'AI CLI Auto Manager home (logs, state, archive, installed copy)\n');
  const result=sync(fx);
  assert.notEqual(result.status,0,'profile root must be refused even with an old help-created marker');
  assert.ok(!fs.existsSync(path.join(fx.home,'app')),'must not install directly in the user profile root');
});


test('purge refuses while another archive or restore holds the maintenance lease', {skip: process.platform === 'win32'}, t => {
  const fx=fixture(t);const first=sync(fx);assert.equal(first.status,0,first.stdout+first.stderr);
  const api=require(path.join(ROOT,'lib/maintenance.js'));
  const saved={};for(const key of ['HOME','USERPROFILE','AICM_HOME']){saved[key]=process.env[key];process.env[key]=fx.env[key];}
  let lock;
  try { lock=api.acquireLock(fx.manager); }
  finally {for(const [key,value] of Object.entries(saved)){if(value===undefined)delete process.env[key];else process.env[key]=value;}}
  try {
    const state=path.join(fx.manager,'state','last-clean.json');put(state,JSON.stringify({ok:true,finishedAt:'2026-10-27T00:00:00Z'}));
    const cron=path.join(fx.top,'fake-crontab');put(cron,'#!/bin/sh\nexit 0\n');fs.chmodSync(cron,0o755);fx.env.AICM_CRONTAB=cron;
    const result=cp.spawnSync('/bin/bash',[path.join(ROOT,'bin/aicm'),'uninstall','--purge'],{env:fx.env,encoding:'utf8',timeout:30000});
    assert.ok(fs.existsSync(path.join(fx.manager,'app','SOURCE')),'must not remove app while maintenance is active');
    assert.ok(fs.existsSync(state),'must not remove metadata while maintenance is active');
    assert.ok(fs.existsSync(path.join(lock.dir,'owner.json')),'must not delete another operation\'s live lease');
    assert.match(result.stdout+result.stderr,/lock|busy|maintenance|running/i);
  } finally { lock.release(); }
});

for (const sourceSelf of [false, true]) for (const relative of ['lib/personal.js', 'bin/personal.sh']) {
  test(`a legacy copy without a roster retains ${relative} (self source: ${sourceSelf})`, {skip: process.platform === 'win32'}, t => {
    const fx=fixture(t); const first=sync(fx); assert.equal(first.status,0,first.stdout+first.stderr);
    fs.unlinkSync(path.join(fx.manager,'app','.aicm-copy'));
    if (sourceSelf) put(path.join(fx.manager,'app','SOURCE'),path.join(fx.manager,'app')+'\n');
    const file=path.join(fx.manager,'app',relative);put(file,'personal source: keep');
    const again=sync(fx);assert.notEqual(again.status,0,'a familiar extension does not prove legacy ownership');
    assert.equal(fs.readFileSync(file,'utf8'),'personal source: keep');
  });
}
