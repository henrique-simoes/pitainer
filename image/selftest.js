#!/usr/bin/env node
// Network checks for one role. Run as that role's user by the entrypoint.
//   selftest.js <role> <public-dns-ip> <gateway-ip> [allowed-host]
'use strict';
const net = require('net');
const dns = require('dns');
const [role, dnsIp, gateway, allowedHost] = process.argv.slice(2);
const T = 3000;
let failed = 0;

function tcp(host, port) {
  return new Promise(res => {
    const s = net.connect({ host, port, timeout: T });
    s.on('connect', () => { s.destroy(); res(true); });
    s.on('timeout', () => { s.destroy(); res(false); });
    s.on('error', () => res(false));
  });
}
function lookup(name) {
  const r = new dns.Resolver({ timeout: T, tries: 1 });
  r.setServers([dnsIp]);
  return new Promise(res => r.resolve4(name, err => res(!err)));
}
// Returns the proxy's status code for CONNECT host:443, or 0 if the proxy is unreachable.
function viaProxy(port, host) {
  const target = host.includes(':') ? host : host + ':443';
  return new Promise(res => {
    const s = net.connect({ host: '127.0.0.1', port, timeout: T * 3 });
    let buf = '';
    s.on('connect', () => s.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`));
    s.on('data', d => { buf += d; const m = /^HTTP\/1\.1 (\d+)/.exec(buf); if (m) { s.destroy(); res(Number(m[1])); } });
    s.on('timeout', () => { s.destroy(); res(0); });
    s.on('error', () => res(0));
    s.on('close', () => res(0));
  });
}
function check(label, got, want) {
  const ok = got === want;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'} [${role}] ${label}${ok ? '' : ` (got ${got}, want ${want})`}`);
}
// Reachability depends on someone else's server being up. At startup that must
// not stop pi, so it only warns; `pitainer test` still treats it as a failure.
const SOFT = process.env.PITAINER_SELFTEST_SOFT === '1';
function reach(label, got) {
  if (got === 200 || !SOFT) return check(label, got, 200);
  console.log(`WARN [${role}] ${label}: not reachable right now`);
}

(async () => {
  const PI = 3128, DEPS = 3129;
  const endpoints = (process.env.PITAINER_PRIVATE_ENDPOINTS || '').split(/[\s,]+/).filter(Boolean);
  const split = e => { const i = e.lastIndexOf(':'); return [e.slice(0, i), Number(e.slice(i + 1))]; };
  check('cannot reach the Mac', await tcp(gateway, 22) || await tcp(gateway, 53), false);
  if (role === 'pxy') {
    check('can reach the internet', await tcp('1.1.1.1', 443), true);
    check('cannot reach private ranges', await tcp('192.168.1.1', 443) || await tcp('10.0.0.1', 443), false);
    process.exit(failed ? 1 : 0);
  }
  check('no direct internet', await tcp('1.1.1.1', 443), false);
  if (role === 'tools') {
    check('no DNS', await lookup('example.com'), false);
    check('pi proxy port refused', await viaProxy(PI, 'example.com'), 0);
    check('deps proxy port refused', await viaProxy(DEPS, 'example.com'), 0);
    for (const e of endpoints) check(`no direct route to private endpoint ${e}`, await tcp(...split(e)), false);
  } else if (role === 'pi') {
    check('no DNS', await lookup('example.com'), false);
    check('proxy refuses other hosts', await viaProxy(PI, 'example.com'), 403);
    check('proxy refuses IP literals', await viaProxy(PI, '1.1.1.1'), 403);
    check('deps proxy port refused', await viaProxy(DEPS, 'example.com'), 0);
    if (allowedHost) reach(`proxy reaches ${allowedHost}`, await viaProxy(PI, allowedHost));
    for (const e of endpoints) {
      const [ip, port] = split(e);
      check(`no direct route to private endpoint ${e}`, await tcp(ip, port), false);
      reach(`proxy reaches private endpoint ${e}`, await viaProxy(PI, e));
      check(`proxy refuses another port on ${ip}`, await viaProxy(PI, `${ip}:${port === 22 ? 23 : 22}`), 403);
    }
  } else if (role === 'deps') {
    check('no DNS', await lookup('example.com'), false);
    check('pi proxy port refused', await viaProxy(PI, 'example.com'), 0);
    check('proxy refuses other hosts', await viaProxy(DEPS, 'example.com'), 403);
    if (allowedHost) reach(`proxy reaches ${allowedHost}`, await viaProxy(DEPS, allowedHost));
    for (const e of endpoints) check(`proxy refuses private endpoint ${e}`, await viaProxy(DEPS, e), 403);
  }
  process.exit(failed ? 1 : 0);
})();
