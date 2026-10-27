// Fake npm/uv/pnpm for tests/node/optimize.test.js: records its name, arguments and the download
// guards it received, then behaves as FAKE_OPTIMIZE_<NAME> says: "ok" (default), "fail" (exit 3) or
// "hang" (starts a grandchild, writes its pid, and waits until stopped). Never touches a real cache.
'use strict';
const fs = require('fs');
const { spawn } = require('child_process');

const name = process.argv[2];
const args = process.argv.slice(3);
const keys = ['COREPACK_ENABLE_NETWORK', 'COREPACK_ENABLE_DOWNLOAD_PROMPT', 'npm_config_offline', 'UV_OFFLINE', 'AICM_MAINTENANCE_LEASE'];
const env = {};
for (const k of keys) env[k] = process.env[k] === undefined ? null : process.env[k];
fs.appendFileSync(process.env.FAKE_OPTIMIZE_CALLS, JSON.stringify({ name, args, env }) + '\n');
const mode = process.env['FAKE_OPTIMIZE_' + name.toUpperCase()] || 'ok';
if (mode === 'fail') { console.error(`${name}: simulated failure`); process.exit(3); }
if (mode === 'hang') {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  fs.writeFileSync(process.env.FAKE_OPTIMIZE_GRANDCHILD, String(child.pid));
  setInterval(() => {}, 1000);
} else {
  console.log(`${name} ${args.join(' ')}: done`);
}
