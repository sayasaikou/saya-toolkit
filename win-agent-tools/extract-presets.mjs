#!/usr/bin/env node
/*
  extract-presets.mjs -- pull built-in preset files out of an Electron app.asar.

  WHY THIS EXISTS
    Some configuration layers override ids that are provided by a BUILT-IN preset.
    Those presets ship inside app.asar, and a plain `node` cannot open an asar archive
    (the format is only understood by Electron's patched fs). After every desktop-client
    upgrade the local mirror must be refreshed; otherwise later tooling compares against
    a stale list and can silently drop entries.

  HOW TO RUN (must be Electron, NOT plain node)
    $env:ELECTRON_RUN_AS_NODE = '1'
    & '<path>\YourApp.exe' "<this script>" --out "$env:USERPROFILE\.app\runtime"

    Plain `node extract-presets.mjs` fails on purpose with a clear message instead of
    writing half a mirror.

  OUTPUT LAYOUT
    <out>\presets\cordis.patch.yml        <- <app>/dsh/node_modules/@deepseek-ai/dsh-web-app/presets/
    <out>\presets\minimal.patch.yml
    <out>\presets\ptc.patch.yml
    <out>\presets\standard.patch.yml
    <out>\web-app.cordis.patch.yml        <- <app>/dsh/node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml
    <out>\VERSION.txt                     <- "@deepseek-ai/dsh-web-app@<version>"

  EXIT CODES
    0  up to date, or files were written
    2  dry run finished and found differences (nothing was written)
    3  error (asar not found, expected files missing)
*/

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';

const APP_REL = 'dsh/node_modules/@deepseek-ai/dsh-web-app';

function parseArgs(argv) {
  const a = { asar: '', out: '', dryRun: false, list: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--asar') a.asar = argv[++i] || '';
    else if (k === '--out') a.out = argv[++i] || '';
    else if (k === '--dry-run') a.dryRun = true;
    else if (k === '--list') a.list = true;
    else if (k === '-h' || k === '--help') { console.log(fs.readFileSync(process.argv[1], 'utf8').split('*/')[0]); process.exit(0); }
    else { console.error('unknown argument: ' + k); process.exit(3); }
  }
  return a;
}

function candidateAsars() {
  const home = os.homedir();
  const cands = [
    process.env.DSH_DESKTOP_ASAR || '',
    path.join(home, 'AppData', 'Local', 'Programs', 'deepseek-harness', 'resources', 'app.asar'),
    path.join(home, 'AppData', 'Local', 'Programs', 'DeepSeek Harness', 'resources', 'app.asar'),
    'C:\\Program Files\\DeepSeek Harness\\resources\\app.asar'
  ].filter(Boolean);
  // NOTE: Electron's asar patch reports an .asar archive as a DIRECTORY, so isFile()
  //       is false for a perfectly good archive -- existence is the only usable test.
  return cands.filter((p) => { try { return fs.existsSync(p); } catch { return false; } });
}

function sha256(buf) { return crypto.createHash('sha256').update(buf).digest('hex'); }

function readInside(p) {
  try { return fs.readFileSync(p); } catch (e) { return null; }
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  // Electron exposes process.versions.electron; plain node does not.
  if (!process.versions.electron) {
    console.error('ERROR: this script must run under Electron with ELECTRON_RUN_AS_NODE=1.');
    console.error('       plain node cannot read app.asar -- see the header of this file.');
    process.exit(3);
  }

  let asar = args.asar;
  if (!asar) {
    const found = candidateAsars();
    if (found.length === 0) {
      console.error('ERROR: no app.asar found. Pass --asar <path to resources\\app.asar>.');
      process.exit(3);
    }
    asar = found[0];
  }
  if (!fs.existsSync(asar)) { console.error('ERROR: asar not found: ' + asar); process.exit(3); }

  const out = args.out || path.join(os.homedir(), '.dsh', 'desktop-runtime');
  const appDir = asar.replace(/[\\/]+$/, '') + '/' + APP_REL;

  if (args.list) {
    const walk = (dir, depth) => {
      if (depth > 4) return;
      let ents = [];
      try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of ents) {
        const p = dir + '/' + e.name;
        if (e.isDirectory()) walk(p, depth + 1);
        else console.log('  ' + p.replace(asar + '/', ''));
      }
    };
    console.log('asar: ' + asar);
    walk(asar, 0);
    return 0;
  }

  const pkgRaw = readInside(appDir + '/package.json');
  if (!pkgRaw) { console.error('ERROR: ' + appDir + '/package.json not readable -- asar layout changed?'); process.exit(3); }
  const pkg = JSON.parse(pkgRaw.toString('utf8'));
  const versionLine = (pkg.name || '@deepseek-ai/dsh-web-app') + '@' + (pkg.version || 'unknown') + '\n';

  const jobs = [];
  let presetNames = [];
  try { presetNames = fs.readdirSync(appDir + '/presets').filter((n) => n.endsWith('.patch.yml')).sort(); }
  catch { console.error('ERROR: ' + appDir + '/presets not readable'); process.exit(3); }
  for (const n of presetNames) jobs.push({ src: appDir + '/presets/' + n, dst: path.join(out, 'presets', n) });
  jobs.push({ src: appDir + '/cordis.patch.yml', dst: path.join(out, 'web-app.cordis.patch.yml') });
  jobs.push({ src: null, dst: path.join(out, 'VERSION.txt'), inline: versionLine });

  console.log('asar   : ' + asar);
  console.log('out    : ' + out);
  console.log('mode   : ' + (args.dryRun ? 'DRY RUN (nothing is written)' : 'WRITE'));
  console.log('version: ' + versionLine.trim());
  console.log('');

  let changed = 0;
  let same = 0;
  for (const j of jobs) {
    const buf = j.src ? readInside(j.src) : Buffer.from(j.inline, 'utf8');
    if (!buf) { console.error('MISSING inside asar: ' + j.src); process.exit(3); }
    const newHash = sha256(buf);
    let oldHash = null;
    try { oldHash = sha256(fs.readFileSync(j.dst)); } catch { /* not there yet */ }
    const status = oldHash === null ? 'NEW    ' : (oldHash === newHash ? 'same   ' : 'CHANGED');
    if (status === 'same   ') same++; else changed++;
    console.log('  ' + status + '  ' + j.dst.replace(os.homedir(), '%USERPROFILE%') + '  (' + buf.length + ' B, sha256 ' + newHash.slice(0, 12) + ')');
    if (!args.dryRun && status !== 'same   ') {
      fs.mkdirSync(path.dirname(j.dst), { recursive: true });
      fs.writeFileSync(j.dst, buf);
    }
  }

  console.log('');
  console.log('summary: ' + same + ' unchanged, ' + changed + ' new/changed');
  if (args.dryRun && changed > 0) { console.log('DRY RUN: re-run without --dry-run to write them.'); return 2; }

  // re-read evidence: every destination must now hash to the asar copy
  if (!args.dryRun) {
    for (const j of jobs) {
      const buf = j.src ? readInside(j.src) : Buffer.from(j.inline, 'utf8');
      const back = fs.readFileSync(j.dst);
      if (sha256(back) !== sha256(buf)) { console.error('RE-READ MISMATCH: ' + j.dst); process.exit(3); }
    }
    console.log('re-read: all ' + jobs.length + ' file(s) match the asar byte for byte');
  }
  return 0;
}

process.exit(main());
