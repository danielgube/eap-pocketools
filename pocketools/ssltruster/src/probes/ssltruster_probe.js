'use strict';

const https = require('node:https');

if (process.argv.length !== 3) {
  console.error('usage: ssltruster_probe.js URL');
  process.exit(2);
}

let settled = false;
const finish = (code, message) => {
  if (settled) return;
  settled = true;
  if (code === 0) console.log(message);
  else console.error(message);
  process.exitCode = code;
};

const request = https.get(process.argv[2], {
  headers: { 'User-Agent': 'EAP-SSLTruster/1.0' },
  timeout: 20000,
}, (response) => {
  response.resume();
  finish(0, String(response.statusCode || 0));
});

request.on('timeout', () => request.destroy(new Error('timeout')));
request.on('error', (error) => finish(1, `${error.name}: ${error.message}`));
