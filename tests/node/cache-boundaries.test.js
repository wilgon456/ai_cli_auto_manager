// Independent cache-budget deletion-boundary and incomplete-scan regressions.
'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const cp=require('node:child_process');
const ROOT=path.resolve(__dirname,'../..');
function put(p,s){fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,s);}
function fixture(t){
 const top=fs.mkdtempSync(path.join(os.tmpdir(),'aicm-budget-review-'));t.after(()=>fs.rmSync(top,{recursive:true,force:true}));
 const home=path.join(top,'home'),cache=path.join(home,'cache'),bin=path.join(top,'bin'),tmp=path.join(top,'tmp');
 for(const p of [cache,bin,tmp])fs.mkdirSync(p,{recursive:true});
 const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('AICM_')));
 Object.assign(env,{HOME:home,USERPROFILE:home,TMPDIR:tmp,AICM_HOME:path.join(home,'.manager'),AICM_OS:'linux',AICM_NOTIFY:'0',AICM_WORKTREES:'0',AICM_PROCESSES:'0',AICM_CLOCK_CHECK:'0',PATH:[bin,path.dirname(process.execPath),'/usr/bin','/bin','/usr/sbin','/sbin'].join(':')});
 const rules=path.join(top,'rules.conf');put(rules,`npm-cache | all | budget | ${cache} | * | 30 | 1 | on | review\n`);
 return {top,home,cache,bin,tmp,env,rules};
}
function tool(fx,n,body){const p=path.join(fx.bin,n);put(p,'#!/bin/sh\n'+body+'\n');fs.chmodSync(p,0o755);}
function oldfile(p){put(p,Buffer.alloc(2*1024*1024,120));const old=new Date(Date.now()-90*86400000);fs.utimesSync(p,old,old);}
function clean(fx){return cp.spawnSync('/bin/bash',[path.join(ROOT,'bin/clean_ai_leftovers.sh'),'--rules-file',fx.rules,'--local-rules-file',path.join(fx.top,'absent'),'--json'],{env:fx.env,encoding:'utf8',timeout:30000});}
test('a file stat failure is a partial scan, never a complete zero-byte cache',{skip:process.platform==='win32'},t=>{
 const fx=fixture(t);const target=path.join(fx.cache,'unstatable.bin');oldfile(target);fx.env.STAT_FAIL_FILE=target;
 tool(fx,'stat','for arg do\n if [ "$arg" = "$STAT_FAIL_FILE" ]; then echo "fixture stat failure" >&2; exit 1; fi\ndone\nexec /usr/bin/stat "$@"');
 tool(fx,'lsof','exit 1');const res=clean(fx);assert.equal(res.status,0,res.stdout+res.stderr);
 const doc=JSON.parse(res.stdout),row=doc.rules.find(x=>x.id==='npm-cache');
 assert.notEqual(row.scanStatus,'complete','a failed stat must not be represented as complete');
 assert.ok(fs.existsSync(target),'incomplete budget scan preserves all data');
});
test('a rule root swapped for a symlink after the scan keeps the original cache files',{skip:process.platform==='win32'},t=>{
 const fx=fixture(t);const name='old.bin';oldfile(path.join(fx.cache,name));const outside=path.join(fx.top,'outside-cache');
 fx.env.CACHE_ROOT=fx.cache;fx.env.CACHE_OUTSIDE=outside;
 tool(fx,'lsof','if [ ! -L "$CACHE_ROOT" ]; then /bin/mv "$CACHE_ROOT" "$CACHE_OUTSIDE" || exit 2; /bin/ln -s "$CACHE_OUTSIDE" "$CACHE_ROOT" || exit 2; fi\nexit 1');
 const res=clean(fx);assert.ok(fs.existsSync(path.join(outside,name)),'must refuse deletion through a newly linked root: '+res.stdout+res.stderr);
 const row=JSON.parse(res.stdout).rules.find(x=>x.id==='npm-cache');assert.notEqual(row.scanStatus,'complete','a changed or linked rule root makes the post-scan incomplete');
});

test('an unreadable depth probe is a partial scan and preserves the cache',{skip:process.platform==='win32'},t=>{
 const fx=fixture(t);const target=path.join(fx.cache,'old.bin');oldfile(target);
 tool(fx,'find','for arg do\n if [ "$arg" = "-mindepth" ]; then echo "fixture depth error" >&2; exit 2; fi\ndone\nexec /usr/bin/find "$@"');
 tool(fx,'lsof','exit 1');const res=clean(fx);assert.equal(res.status,0,res.stdout+res.stderr);
 const row=JSON.parse(res.stdout).rules.find(x=>x.id==='npm-cache');assert.notEqual(row.scanStatus,'complete');assert.ok(fs.existsSync(target),'failed depth enumeration must preserve all files');
});

test('an incomplete candidate enumeration preserves every budget candidate',{skip:process.platform==='win32'},t=>{
 const fx=fixture(t);const target=path.join(fx.cache,'old.bin');oldfile(target);
 tool(fx,'find','candidate=0\nfor arg do [ "$arg" != "-name" ] || candidate=1; done\n/usr/bin/find "$@"\n[ "$candidate" = 0 ] || { echo "fixture candidate enumeration error" >&2; exit 2; }');
 tool(fx,'lsof','exit 1');const res=clean(fx);assert.equal(res.status,0,res.stdout+res.stderr);
 const row=JSON.parse(res.stdout).rules.find(x=>x.id==='npm-cache');assert.notEqual(row.scanStatus,'complete');assert.ok(fs.existsSync(target),'partial candidate enumeration must not delete its partial results');
});
