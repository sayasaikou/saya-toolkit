#!/usr/bin/env node
// sync-budget-preset.mjs
// ---------------------------------------------------------------------------
// 把「随包内置的 standard preset」同步成 profile patch 里的 DSH-BUDGET-OVERRIDE 块，
// 全程只改一处：agent-instructions.maxBytes。
//
// 为什么要它：官方文档明确写着 ——
//   「用户覆盖替换完整子插件列表，不自动合并内置列表的未来更新。」
// 每轮 DSH 升级后内置列表可能变，人手抄必然漂移：
//   2026-09-28 就因为旧写法打空过一次；同日又发现块里把内置的 `|` 块标量
//   抄成了 `>`，plan-mode 提示词的换行结构跟内置不一致。
// 本脚本的做法是「整份照抄 + 只替换一行」，任何内置变化都会自动跟随。
//
// 用法：
//   node sync-budget-preset.mjs            # 干跑：只打印差异，不写文件
//   node sync-budget-preset.mjs -Apply     # 写入（自动备份 + 回读校验）
//   node sync-budget-preset.mjs -Apply -MaxBytes 262144
// 退出码：0 = 一致 / 已写入；2 = 有差异（干跑模式）；1 = 出错
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

// ---- 1. 读内置，取出 preset 声明并去掉 `- insert:` 包裹（每行减 4 空格）----
const raw = fs.readFileSync(BUILTIN, 'utf8');
const nl = raw.includes('\r\n') ? '\r\n' : '\n';
const srcLines = raw.split(/\r?\n/);
const insertAt = srcLines.findIndex((l) => l.trim() === '- insert:');
if (insertAt < 0) die('no insert row in builtin preset (format changed?)');
const body = srcLines.slice(insertAt + 1);
while (body.length && body[body.length - 1].trim() === '') body.pop();
let decl = body.map((l) => (l.startsWith('    ') ? l.slice(4) : l));
if (!decl[0] || !decl[0].startsWith('- id:')) die('unexpected shape after de-indent: ' + JSON.stringify(decl[0]));

// ---- 2. 只替换 maxBytes 那一行 ----
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

// ---- 3b. 自检：把 maxBytes 还原回内置值后，必须与内置体逐行全等 ----
// 这是本工具的核心保证：万一上游改了格式（换标量风格 / 换缩进 / 加新键），
// 机械变换就可能悄悄产出错块 —— 这里直接拒绝写入，而不是写进去等重启才炸。
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
// ---- 3. 组装新块 ----
const header = [
  MARK_A + ' (managed by sync-budget-preset.mjs - do NOT hand-edit this block)',
  '# 来源：dsh-web-app@' + dshVer + ' presets/standard.patch.yml（整份照抄，只改下面那一行 maxBytes）',
  '# 重新生成：node ' + path.join(DSH_HOME, 'sync-budget-preset.mjs') + ' -Apply　｜　干跑（只看差异）：去掉 -Apply',
  '# 为什么：全局 + 工作区两份 AGENTS.md 合计约 145 KB，随包 65536 装不下，',
  '#   而机制的取舍是「保住更具体的工作区那份、把全局那份整份丢掉」——不报错、不崩溃，',
  '#   只是规则写了却看不见（2026-09-17 踩过）。',
  '# 回滚：整块删掉即退回随包 65536（改完要重启服务 + 开新会话才验证得到）。',
];
// 注：块的最终形态 = header + decl + MARK_B，按 patch 文件自己的行尾写回。

// ---- 4. 与现状比对 ----
// 详细报告走 say()：--brief 下只有 process.on('exit') 那一行 RESULT。
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

// ---- 5. 写入：备份 + 替换 + 回读 ----
const stamp = fmtStamp(new Date());
exitCode = 0;
exitMsg = 'override block rewritten' + (diff ? ' (' + diff + ' line(s) updated)' : ' (header refreshed only)');
const bkp = PATCH + '.bak-' + stamp;
fs.copyFileSync(PATCH, bkp);
const rebuilt = pLines.slice(0, a).concat(newLinesArr, pLines.slice(b + 1)).join(pnl);
fs.writeFileSync(PATCH, rebuilt, 'utf8');

// ---- 6. 回读校验 ----
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
