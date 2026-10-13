#!/usr/bin/env node
// Allow-list egress proxy. The only process the firewall lets out of the container.
// Each listener has its own host list: one for pi (model providers), one for the
// user-run dependency path (package indexes). HTTPS CONNECT to port 443 only.
'use strict';
const http = require('http');
const net = require('net');
const dns = require('dns');
const fs = require('fs');

const LISTENERS = [
  { name: 'pi', port: 3128, file: '/run/pitainer/pi.hosts', endpoints: '/run/pitainer/pi.endpoints' },
  { name: 'deps', port: 3129, file: '/run/pitainer/deps.hosts' },
];

function log(...a) { process.stderr.write(new Date().toISOString() + ' ' + a.join(' ') + '\n'); }

// `*` matches one DNS label; a leading `*.` matches one or more labels.
function compile(pattern) {
  let p = pattern, prefix = '';
  if (p.startsWith('*.')) { prefix = '(?:[a-z0-9-]+\\.)+'; p = p.slice(2); }
  const body = p.split('*').map(s => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[a-z0-9-]+');
  return new RegExp('^' + prefix + body + '$');
}

function loadList(file) {
  return fs.readFileSync(file, 'utf8').split(/[\n,]/).map(s => s.trim().toLowerCase())
    .filter(s => s && !s.startsWith('#')).map(compile);
}

function isPrivate(ip) {
  const o = ip.split('.').map(Number);
  return o[0] === 0 || o[0] === 10 || o[0] === 127 || o[0] >= 224 ||
    (o[0] === 100 && o[1] >= 64 && o[1] <= 127) || (o[0] === 169 && o[1] === 254) ||
    (o[0] === 172 && o[1] >= 16 && o[1] <= 31) || (o[0] === 192 && o[1] === 168) ||
    (o[0] === 192 && o[1] === 0 && o[2] === 0) || (o[0] === 198 && (o[1] === 18 || o[1] === 19));
}

// Private endpoints: exact "ip:port" targets the user opted into (for example a
// model server on a VPN). They bypass the hostname and private-address checks.
function loadEndpoints(file) {
  if (!file || !fs.existsSync(file)) return new Set();
  return new Set(fs.readFileSync(file, 'utf8').split('\n').map(s => s.trim()).filter(Boolean));
}

function serve({ name, port, file, endpoints }) {
  const list = loadList(file);
  const direct = loadEndpoints(endpoints);
  const server = http.createServer((req, res) => {
    log('DENY', name, 'plain-http', req.url);
    res.writeHead(403, { 'content-type': 'text/plain' });
    res.end('pitainer proxy: HTTPS CONNECT only\n');
  });
  server.on('connect', (req, client) => {
    const deny = why => {
      log('DENY', name, req.url, why);
      client.end('HTTP/1.1 403 Forbidden\r\nX-Pitainer: ' + why + '\r\n\r\n');
    };
    client.on('error', () => {});
    const tunnel = (address, toPort) => {
      const upstream = net.connect(toPort, address, () => {
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        upstream.pipe(client);
        client.pipe(upstream);
      });
      upstream.on('error', () => client.destroy());
      client.on('close', () => upstream.destroy());
    };
    if (direct.has(req.url)) {
      const i = req.url.lastIndexOf(':');
      return tunnel(req.url.slice(0, i), Number(req.url.slice(i + 1)));
    }
    const m = /^([^:]+):(\d+)$/.exec(req.url || '');
    if (!m) return deny('bad-target');
    const host = m[1].toLowerCase().replace(/\.$/, '');
    if (m[2] !== '443') return deny('port-not-443');
    if (net.isIP(host)) return deny('ip-literal');
    if (!list.some(re => re.test(host))) return deny('host-not-allowed');
    dns.lookup(host, { family: 4 }, (err, address) => {
      if (err) return deny('dns-failed');
      if (isPrivate(address)) return deny('private-address');
      tunnel(address, 443);
    });
  });
  server.listen(port, '127.0.0.1', () => log('LISTEN', name, port, list.length + ' patterns', direct.size + ' private endpoints'));
}

LISTENERS.forEach(serve);
