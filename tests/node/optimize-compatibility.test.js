// Compatibility contracts for package-manager bootstrap, process metadata and busy ancestors.
'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),cp=require('node:child_process');
const ROOT=path.resolve(__dirname,'../..'),JS=path.join(ROOT,'lib/optimize.js'),opt=require(JS);
function fixture(t){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'aicm-opt-compat-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true,maxRetries:3,retryDelay:100}));
 const home=path.join(dir,'home'),manager=path.join(home,'.manager'),bin=path.join(dir,'bin'),helper=path.join(dir,'vendor.js'),calls=path.join(dir,'calls.jsonl'),download=path.join(dir,'download-attempt'),table=path.join(dir,'processes.json');
 for(const p of [manager,bin])fs.mkdirSync(p,{recursive:true});
 fs.writeFileSync(path.join(manager,'.aicm-home'),'AI CLI Auto Manager home (logs, state, archive, installed copy)\n');
 fs.writeFileSync(table,JSON.stringify([{pid:1,ppid:0,name:'init',cmd:'init'}]));
 const expected={COREPACK_ENABLE_NETWORK:'0',COREPACK_ENABLE_PROJECT_SPEC:'0',COREPACK_ENV_FILE:'0',npm_config_offline:'true',npm_config_manage_package_manager_versions:'false',pnpm_config_offline:'true',pnpm_config_pm_on_fail:'ignore'};
 fs.writeFileSync(helper,`const fs=require('fs');const expected=${JSON.stringify(expected)};if(process.env.REVIEW_GUARDS==='1'){for(const [name,value]of Object.entries(expected)){const keys=Object.keys(process.env).filter(k=>k.toLowerCase()===name.toLowerCase());if(keys.length!==1||process.env[keys[0]]!==value){fs.writeFileSync(process.env.REVIEW_DOWNLOAD,name);process.exit(17);}}}fs.appendFileSync(process.env.REVIEW_CALLS,JSON.stringify(process.argv.slice(2))+'\\n');`);
 for(const tool of ['npm','uv','pnpm']){
  const exe=path.join(bin,tool+(process.platform==='win32'?'.cmd':''));
  fs.writeFileSync(exe,process.platform==='win32'?`@echo off\r\n"%REVIEW_NODE%" "%REVIEW_HELPER%" ${tool} %*\r\n`:`#!/bin/sh\nexec "$REVIEW_NODE" "$REVIEW_HELPER" ${tool} "$@"\n`);if(process.platform!=='win32')fs.chmodSync(exe,0o755);
 }
 const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('AICM_')&&!['path','home','userprofile'].includes(k.toLowerCase())));
 Object.assign(env,{HOME:home,USERPROFILE:home,AICM_HOME:manager,AICM_PROCESS_LIST:table,PATH:[bin,...(process.platform==='win32'?[path.join(process.env.SystemRoot,'System32')]:['/usr/bin','/bin'])].join(path.delimiter),REVIEW_NODE:process.execPath,REVIEW_HELPER:helper,REVIEW_CALLS:calls,REVIEW_DOWNLOAD:download});
 return {dir,home,manager,bin,env,calls,download,table};
}
function run(fx,extra={}){return cp.spawnSync(process.execPath,[JS,'--apply','--tasks','npm-verify,pnpm-prune','--json'],{cwd:fx.dir,env:{...fx.env,...extra},encoding:'utf8',timeout:20000});}

test('cache maintenance blocks project pnpm bootstrap across versions and overrides mixed-case flags',t=>{
 const fx=fixture(t);fs.writeFileSync(path.join(fx.dir,'package.json'),JSON.stringify({packageManager:'pnpm@12.0.0'}));
 const r=run(fx,{REVIEW_GUARDS:'1',NPM_CONFIG_OFFLINE:'false',PNPM_CONFIG_PM_ON_FAIL:'download',corepack_enable_network:'1'});
 assert.equal(r.status,0,r.stdout+r.stderr);assert.ok(!fs.existsSync(fx.download),'must not trigger project package-manager downloads');
 assert.deepEqual(fs.readFileSync(fx.calls,'utf8').trim().split('\n').map(JSON.parse),[['npm','cache','verify'],['pnpm','store','prune']]);
});

test('a package-manager ancestor remains busy even though it started the optimizer',()=>{
 const task=opt.TASKS.find(t=>t.id==='npm-verify');const rows=[{pid:10,ppid:1,name:'node',cmd:'node /x/npm/bin/npm-cli.js exec aicm'},{pid:process.pid,ppid:10,name:'node',cmd:'node lib/optimize.js'}];
 assert.deepEqual(opt.busyPids(task,rows,new Set([10,process.pid])),[10]);
});

test('unquoted executable and npm script paths with spaces are recognized as busy',()=>{
 const npm=opt.TASKS.find(t=>t.id==='npm-verify'),uv=opt.TASKS.find(t=>t.id==='uv-prune');
 assert.deepEqual(opt.busyPids(npm,[{pid:90001,ppid:1,name:'runtime',cmd:'/tmp/runtime with spaces/node /tmp/tools with spaces/npm-cli.js install'}],new Set()),[90001]);
 assert.deepEqual(opt.busyPids(uv,[{pid:90002,ppid:1,name:'runtime',cmd:'/tmp/runtime with spaces/uv cache prune'}],new Set()),[90002]);
});

test('an unreadable Node command line cannot establish that the npm cache is idle',t=>{
 const fx=fixture(t);fs.writeFileSync(fx.table,JSON.stringify([{pid:1,ppid:0,name:'init',cmd:'init'},{pid:90003,ppid:1,name:'node.exe',cmd:''}]));
 const r=run(fx);assert.notEqual(r.status,0,r.stdout+r.stderr);assert.ok(!fs.existsSync(fx.calls),'must hold npm/pnpm when a Node command line cannot be inspected');
 const d=JSON.parse(r.stdout);assert.ok(d.tasks.every(t=>t.status==='skipped'||t.status==='busy'));
});
