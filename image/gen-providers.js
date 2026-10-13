#!/usr/bin/env node
// Derive the provider host list from the installed pi version.
// For each provider pi ships, collect every https host named in that provider's
// implementation, catalog data and sign-in code. Output: "<provider> <host>" lines.
// Placeholders such as {region} or ${resource} become `*` (one DNS label).
// The result is a candidate list: it is committed as providers.lock and reviewed.
'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const root = execSync('npm root -g').toString().trim();
const ai = path.join(root, '@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist');
const providersDir = path.join(ai, 'providers');
const oauthDir = path.join(ai, 'auth/oauth');

const providers = fs.readdirSync(providersDir).filter(f => f.endsWith('.models.js'))
  .map(f => f.slice(0, -'.models.js'.length)).sort();
const oauthFiles = fs.existsSync(oauthDir) ? fs.readdirSync(oauthDir).filter(f => f.endsWith('.js')) : [];

function hosts(file) {
  if (!fs.existsSync(file)) return [];
  const text = fs.readFileSync(file, 'utf8');
  const out = [];
  for (const m of text.matchAll(/https:\/\/((?:[A-Za-z0-9-]+|\{[A-Za-z_]+\}|\$\{[A-Za-z_.]+\})(?:\.(?:[A-Za-z0-9-]+|\{[A-Za-z_]+\}|\$\{[A-Za-z_.]+\}))+)/g)) {
    const h = m[1].replace(/\$?\{[^}]+\}/g, '*').toLowerCase();
    if (/\.[a-z]{2,}$/.test(h) && !/^\*(\.\*)*$/.test(h)) out.push(h);
  }
  return out;
}

const lines = new Set();
for (const p of providers) {
  const files = [
    path.join(providersDir, p + '.js'),
    path.join(providersDir, 'data', p + '.json'),
    ...oauthFiles.filter(f => f === p + '.js' || f.startsWith(p + '-') || p.startsWith(f.slice(0, -3)))
      .map(f => path.join(oauthDir, f)),
  ];
  for (const f of files) for (const h of hosts(f)) lines.add(`${p} ${h}`);
}
process.stdout.write([...lines].sort().join('\n') + '\n');
