// Parent regression: cancellation must finish owned cache children before releasing their lease.
'use strict';
const test=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const os=require('node:os');const path=require('node:path');const cp=require('node:child_process');
const ROOT=path.resolve(__dirname,'../..');const sleep=ms=>new Promise(r=>setTimeout(r,ms));
for (const signal of ['SIGTERM', 'SIGINT']) test(`${signal}: cancelled optimize stops a TERM-ignoring owned command before releasing maintenance`,{skip:process.platform==='win32',timeout:18000},async t=>{
 const top=fs.mkdtempSync(path.join(os.tmpdir(),'aicm-opt-review-'));const home=path.join(top,'home'),manager=path.join(home,'.manager'),bin=path.join(top,'bin'),helper=path.join(top,'cache-child.js'),pidfile=path.join(top,'pid'),heartbeat=path.join(top,'heartbeat'),processes=path.join(top,'processes.json');
 for(const p of [manager,bin])fs.mkdirSync(p,{recursive:true});
 fs.writeFileSync(path.join(manager,'.aicm-home'),'AI CLI Auto Manager home (logs, state, archive, installed copy)\n');
 fs.writeFileSync(processes,JSON.stringify([{pid:1,ppid:0,name:'init',cmd:'init'}]));
 fs.writeFileSync(helper,`const fs=require('fs');process.on('SIGTERM',()=>{});fs.writeFileSync(process.env.REVIEW_PID,String(process.pid));setInterval(()=>fs.appendFileSync(process.env.REVIEW_HEARTBEAT,'x'),30);`);
 const shim=path.join(bin,'npm');fs.writeFileSync(shim,'#!/bin/sh\nexec "$REVIEW_NODE" "$REVIEW_HELPER" "$@"\n');fs.chmodSync(shim,0o755);
 const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('AICM_')));
 Object.assign(env,{HOME:home,USERPROFILE:home,AICM_HOME:manager,AICM_PROCESS_LIST:processes,AICM_OPTIMIZE_TIMEOUT:'20',AICM_NOTIFY:'0',PATH:[bin,path.dirname(process.execPath),'/usr/bin','/bin','/usr/sbin','/sbin'].join(':'),REVIEW_NODE:process.execPath,REVIEW_HELPER:helper,REVIEW_PID:pidfile,REVIEW_HEARTBEAT:heartbeat});
 const child=cp.spawn(process.execPath,[path.join(ROOT,'lib/optimize.js'),'--apply','--tasks','npm-verify','--json'],{env,cwd:ROOT,stdio:['ignore','pipe','pipe']});let output='';child.stdout.on('data',d=>{output+=d;});child.stderr.on('data',d=>{output+=d;});let taskPid;
 t.after(async()=>{
  if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
  if(taskPid){const cmd=cp.spawnSync('/bin/ps',['-p',String(taskPid),'-o','command='],{encoding:'utf8'}).stdout||'';if(cmd.includes(helper)){try{process.kill(-taskPid,'SIGKILL');}catch{}}}
  await sleep(80);fs.rmSync(top,{recursive:true,force:true});
 });
 for(let i=0;i<300&&!fs.existsSync(heartbeat);i++){if(child.exitCode!==null)break;await sleep(20);}
 assert.ok(fs.existsSync(pidfile)&&fs.existsSync(heartbeat),'owned fake task must start: '+output);taskPid=Number(fs.readFileSync(pidfile,'utf8'));
 const exited=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('optimizer did not stop in time')),7000);child.once('exit',()=>{clearTimeout(timer);resolve();});});
 child.kill(signal);await exited;
 assert.equal(child.exitCode,signal==='SIGINT'?130:143,'signal exit status');
 const before=fs.statSync(heartbeat).size;await sleep(200);const after=fs.statSync(heartbeat).size;
 assert.equal(after,before,'cache command kept mutating after optimizer exited and released its lease');
 assert.ok(!fs.existsSync(path.join(manager,'state','maintenance.lock')),'lease must release after the owned command stops');
});
