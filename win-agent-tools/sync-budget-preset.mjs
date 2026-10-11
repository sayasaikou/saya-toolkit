#!/usr/bin/env node
// sync-budget-preset.mjs
// ---------------------------------------------------------------------------
// Keep the DSH-BUDGET-OVERRIDE block in the profile patch in sync with the
// standard preset that ships inside the package. Exactly one value is changed:
// agent-instructions.maxBytes.
//
// WHY THIS EXISTS:
//   Upstream documents that a user override REPLACES the whole sub-plugin list and does
//   NOT merge future changes to the builtin list. That list can change on any release,
//   and copying it by hand drifts: it has silently gone stale once, and a hand-copied
//   block turned a `|` block scalar into `>` -- which changes how a multi-line prompt is
//   folded even though the text looks the same.
//
//   So this copies the whole block verbatim and rewrites ONLY the maxBytes line, and any
//   upstream change is carried over instead of being missed.
//
// USAGE:
//   node sync-budget-preset.mjs            # dry run: print the diff, write nothing
//   node sync-budget-preset.mjs -Apply     # write (backup + read-back verification)
//   node sync-budget-preset.mjs -Apply -MaxBytes 262144
//   node sync-budget-preset.mjs --brief    # single RESULT line, for callers
// Exit codes: 0 = identical / written | 2 = differences (dry run) | 1 = error
// ---------------------------------------------------------------------------


import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const argv = process.argv.slice(2);
const APPLY = argv.includes('-Apply');
const mbIdx = argv.indexOf('-MaxBytes');
const MAX_BYTES = mbIdx >= 0 && argv[mbIdx + 1] ? parseInt(argv[mbIdx + 1], 10) : 262144;

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const APPDATA = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
const DSH_PKG = path.join(APPDATA, 'npm', 'node_modules', '@deepseek-ai', 'dsh');
// 2026-09-30: the active profile belongs to the official Electron desktop client, and
// its builtin preset ships INSIDE app.asar -- plain node cannot read it. That migration
// mirrors the package presets to $DSH_HOME\desktop-runtime\presets\. Prefer the mirror;
// fall back to the old global-npm CLI for as long as it still exists.
const BUILTIN_DESKTOP = path.join(DSH_HOME, 'desktop-runtime', 'presets', 'standard.patch.yml');
const BUILTIN_NPM = path.join(DSH_PKG, 'node_modules', '@deepseek-ai', 'dsh-web-app', 'presets', 'standard.patch.yml');
const BUILTIN = fs.existsSync(BUILTIN_DESKTOP) ? BUILTIN_DESKTOP : BUILTIN_NPM;
const PATCH = path.join(DSH_HOME, 'profiles', 'desktop', 'cordis.patch.yml');
const MARK_A = '# >>> DSH-BUDGET-OVERRIDE';
const MARK_B = '# <<< DSH-BUDGET-OVERRIDE';

// `--brief` (alias `-b`): the ONLY output is a single `RESULT: ...` line, so callers
// (upgrade-dsh-core.ps1 after every core upgrade, update-check.ps1 on session start)
// can log/parse one line instead of the full verbose report. Errors still go to stderr.
const BRIEF = argv.includes('--brief') || argv.includes('-b');
function say(s) { if (!BRIEF) console.log(s); }

function pad2(n) { return String(n).padStart(2, '0'); }
function fmtStamp(d) { return '' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) + '-' + pad2(d.getHours()) + pad2(d.getMinutes()); }

function die(msg) { console.error('ERROR: ' + msg); process.exit(1); }

if (!fs.existsSync(BUILTIN)) die('builtin preset not found: ' + BUILTIN);
if (!fs.existsSync(PATCH)) die('profile patch not found: ' + PATCH);

let dshVer = 'unknown';
try {
  if (BUILTIN === BUILTIN_DESKTOP) {
    dshVer = fs.readFileSync(path.join(DSH_HOME, 'desktop-runtime', 'VERSION.txt'), 'utf8').trim().replace(/^.*@/, '');
  } else {
    dshVer = JSON.parse(fs.readFileSync(path.join(DSH_PKG, 'package.json'), 'utf8')).version;
  }
} catch {}

// ---- 1. read the builtin, take the preset declaration and strip the `- insert:` wrapper ----
// (every line of the wrapped block is indented by 4 spaces)
const raw = fs.readFileSync(BUILTIN, 'utf8');
const nl = raw.includes('\r\n') ? '\r\n' : '\n';
const srcLines = raw.split(/\r?\n/);
const insertAt = srcLines.findIndex((l) => l.trim() === '- insert:');
if (insertAt < 0) die('no insert row in builtin preset (format changed?)');
const body = srcLines.slice(insertAt + 1);
while (body.length && body[body.length - 1].trim() === '') body.pop();
let decl = body.map((l) => (l.startsWith('    ') ? l.slice(4) : l));
if (!decl[0] || !decl[0].startsWith('- id:')) die('unexpected shape after de-indent: ' + JSON.stringify(decl[0]));

// ---- 2. rewrite the maxBytes line only ----
let hits = 0;
let builtinMax = null;
decl = decl.map((l) => {
  const m = l.match(/^(\s*)maxBytes:\s*(\d+)\s*$/);
  if (!m) return l;
  hits++;
  builtinMax = m[2];
  return m[1] + 'maxBytes: ' + MAX_BYTES;
});
if (hits !== 1) die('expected exactly 1 maxBytes line in builtin preset, found ' + hits);

// ---- 3b. self-check: restoring maxBytes must make the block line-identical to the builtin ----
// This is the core guarantee of the tool. If upstream changes the format (scalar style,
// indentation, a new key), the mechanical transform could silently emit a wrong block --
// so refuse to write instead of writing and finding out after a restart.
{
  const biBody = body.map((l) => (l.startsWith('    ') ? l.slice(4) : l)).filter((l) => l.trim() !== '');
  const back = decl.map((l) => l.replace(/^(\s*)maxBytes:\s*\d+\s*$/, '$1maxBytes: ' + builtinMax));
  const backBody = back.filter((l) => l.trim() !== '');
  let bad = 0;
  const n = Math.max(biBody.length, backBody.length);
  for (let i = 0; i < n; i++) if (biBody[i] !== backBody[i]) bad++;
  if (bad !== 0) die('self-check FAILED: de-indented block differs from builtin in ' + bad + ' line(s) - upstream format changed, refusing to write');
  say('self-check: de-indent round-trip is line-identical to builtin (' + biBody.length + ' lines); the only change is maxBytes ' + builtinMax + ' -> ' + MAX_BYTES);
}
// ---- 3. assemble the new block ----
const header = [
  MARK_A + ' (managed by sync-budget-preset.mjs - do NOT hand-edit this block)',
  '# source: the builtin presets/standard.patch.yml of the installed host @' + dshVer,
  '# regenerate: node ' + path.join(DSH_HOME, 'sync-budget-preset.mjs') + ' -Apply  |  dry run: drop -Apply',
  '# why: the builtin agent-instructions budget is smaller than a typical combined',
  '#   global + workspace AGENTS.md. The mechanism resolves the overflow by keeping the',
  '#   more specific workspace copy and DROPPING the global one entirely -- no error, no',
  '#   crash, the rules are simply not in effect. That failure mode has been observed.',
  '# rollback: delete the whole block to fall back to the builtin value. Restart the',
  '#   service and open a new session before the change is observable.',
];
// note: the final block is header + decl + MARK_B, written with the patch file own EOL.

// ---- 4. compare with the current state ----
// The verbose report goes through say(); under --brief only the exit hook prints.
const patchRaw = fs.readFileSync(PATCH, 'utf8');
const pnl = patchRaw.includes('\r\n') ? '\r\n' : '\n';
const pLines = patchRaw.split(/\r?\n/);
const a = pLines.findIndex((l) => l.startsWith(MARK_A));
const b = pLines.findIndex((l) => l.startsWith(MARK_B));
if (a < 0 || b < 0 || b < a) die('budget block markers not found in ' + PATCH);
const oldBlock = pLines.slice(a, b + 1).join(pnl);

say('builtin   : ' + BUILTIN);
say('           dsh-web-app@' + dshVer + ', ' + srcLines.length + ' lines -> ' + decl.length + ' decl lines, maxBytes=' + MAX_BYTES);
say('patch     : ' + PATCH);
say('block     : lines ' + (a + 1) + '-' + (b + 1) + ' (' + (b - a + 1) + ' lines)');
say('');

const oldBody = pLines.slice(a, b + 1).filter((l) => !l.startsWith('#') && l.trim() !== '');
const newBody = decl.filter((l) => l.trim() !== '');
let diff = 0;
const maxN = Math.max(oldBody.length, newBody.length);
for (let i = 0; i < maxN; i++) {
  if (oldBody[i] !== newBody[i]) {
    if (diff < 12) say('  DIFF #' + (i + 1) + ':\n    old> ' + (oldBody[i] === undefined ? '(none)' : oldBody[i]) + '\n    new> ' + (newBody[i] === undefined ? '(none)' : newBody[i]));
    diff++;
  }
}
say(diff === 0 ? 'RESULT: no diff, nothing to do' : 'RESULT: ' + diff + ' line(s) differ (showing at most 12)');

const newLinesArr = header.concat(decl, [MARK_B]);
const oldLinesArr = pLines.slice(a, b + 1);
const blockSame = oldLinesArr.length === newLinesArr.length && oldLinesArr.every((l, i) => l === newLinesArr[i]);
let exitCode = 0;
let exitMsg = diff === 0 ? 'no diff, nothing to do' : diff + ' line(s) differ (showing at most 12)';
// Single-line contract for callers (--brief): printed on EVERY exit path, including
// 'dry-run found a diff' (rc=2), errors (rc=1) and the auto-rollback path.
process.on('exit', (code) => {
  if (BRIEF) console.log('RESULT: rc=' + (code === undefined ? exitCode : code) + '  ' + exitMsg);
});
if (diff === 0 && blockSame) process.exit(0);
if (!APPLY) { exitCode = 2; say('(dry-run: nothing written. add -Apply to write)'); process.exit(2); }

// ---- 5. write: backup + replace + read back ----
const stamp = fmtStamp(new Date());
exitCode = 0;
exitMsg = 'override block rewritten' + (diff ? ' (' + diff + ' line(s) updated)' : ' (header refreshed only)');
const bkp = PATCH + '.bak-' + stamp;
fs.copyFileSync(PATCH, bkp);
const rebuilt = pLines.slice(0, a).concat(newLinesArr, pLines.slice(b + 1)).join(pnl);
fs.writeFileSync(PATCH, rebuilt, 'utf8');

// ---- 6. read-back verification ----
const after = fs.readFileSync(PATCH, 'utf8').split(/\r?\n/);
const a2 = after.findIndex((l) => l.startsWith(MARK_A));
const b2 = after.findIndex((l) => l.startsWith(MARK_B));
const okMarkers = a2 >= 0 && b2 > a2;
const okBytes = after.some((l) => /^\s*maxBytes:\s*262144\s*$/.test(l));
const okId = after.some((l) => l.trim() === '- id: preset-standard');
say('');
say('backup    : ' + bkp);
say('written   : ' + PATCH + '  (' + rebuilt.length + ' chars)');
say('readback  : markers=' + okMarkers + '  maxBytes262144=' + okBytes + '  preset-standard-row=' + okId);
if (!(okMarkers && okBytes && okId)) {
  console.error('READBACK FAILED - restoring backup');
  fs.copyFileSync(bkp, PATCH);
  exitCode = 1;
  exitMsg = 'applied but READBACK FAILED - auto-rolled back';
  process.exit(1);
}
say('VERDICT: OK (restart the service + open a new session to take effect)');
