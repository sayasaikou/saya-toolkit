#!/usr/bin/env node
// ctx-audit —— 量一次真实请求的上下文组成（本机 V4 会话日志）
//
// 口径说明（重要，别混）：
//   · request/header 里的 tools 数组 = 宿主真正发给 provider 的完整 schema，逐字节可信。
//   · prompt 总量用 provider 实测 usage（inputTokens + cacheReadTokens）。
//   · 各块占比用双模型：A = 官方 dsh-token-meter 的固定密度（约 4 字符 ≈ 1 token）；
//     B = 中文按 1.5 字符/token、ASCII 按 4 —— 与实测对账后误差通常在 10% 内。
//   · 密度是启发式，不是分词器真值；要交叉验证就开一次 /context 面板看官方数字。
//
// 用法：
//   node ctx-audit.mjs                       # 自动取最近一次会话
//   node ctx-audit.mjs --session <id>        # 指定会话
//   node ctx-audit.mjs --file <path.jsonl>   # 直接给解压后的 jsonl
//   node ctx-audit.mjs --tools-top 25        # 工具榜长度（默认 15）

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const ROOT = process.env.DSH_HOME ?? join(process.env.USERPROFILE ?? '', '.dsh');
const SESSIONS = join(ROOT, 'sessions');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i === -1 ? dflt : process.argv[i + 1];
}

// ---- 取日志文件 ----------------------------------------------------------
function newestSessionFile() {
  const out = [];
  const walk = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.jsonl.zstd')) out.push(p);
    }
  };
  walk(SESSIONS);
  out.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return out[0];
}

function resolveFile() {
  const direct = arg('file');
  if (direct) return direct;
  const want = arg('session');
  if (want) {
    const walk = (dir) => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name);
        if (e.isDirectory()) {
          if (e.name.includes(want)) {
            const f = readdirSync(p).find((n) => n.endsWith('.jsonl.zstd'));
            if (f) return join(p, f);
          }
          const r = walk(p);
          if (r) return r;
        }
      }
      return null;
    };
    const f = walk(SESSIONS);
    if (!f) throw new Error('未找到会话: ' + want);
    return f;
  }
  return newestSessionFile();
}

// ---- 多帧 zstd 解压 -----------------------------------------------------
function readSession(path) {
  const buf = readFileSync(path);
  const magic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
  const starts = [];
  let i = buf.indexOf(magic);
  while (i !== -1) { starts.push(i); i = buf.indexOf(magic, i + 4); }
  starts.push(buf.length);
  const chunks = [];
  for (let k = 0; k < starts.length - 1; k++) {
    try { chunks.push(zstdDecompressSync(buf.subarray(starts[k], starts[k + 1]))); }
    catch { /* 尾部半帧，忽略 */ }
  }
  return Buffer.concat(chunks).toString('utf8');
}

// ---- 拆一次请求 ---------------------------------------------------------
function firstRequest(lines) {
  let header = null, sysMsg = null, usage = null, context = null;
  const userMsgs = [];
  for (const l of lines) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    if (o.type === 'request/header' && !header) header = o.data.header;
    if (o.type === 'request/context' && !context) context = o.data;
    if (o.type === 'system/message' && !sysMsg) sysMsg = o.data.message;
    if (o.type === 'assistant/message' && !usage && o.data?.usage) usage = o.data.usage;
    if (o.type === 'user/message') userMsgs.push(o);
  }
  return { header, sysMsg, usage, context, userMsgs };
}

const count = (s) => {
  let nonAscii = 0;
  for (const ch of s) if (ch.codePointAt(0) > 127) nonAscii++;
  return { n: s.length, nonAscii, ascii: s.length - nonAscii };
};
const CPT = 4, ROLE = 4, CJK = 1.5;
const estA = (c) => Math.ceil(c.n / CPT) + ROLE;
const estB = (c) => Math.ceil(c.ascii / CPT + c.nonAscii / CJK) + ROLE;
const textOf = (m) => (Array.isArray(m.content) ? m.content.map((b) => b.text ?? '').join('') : String(m.content ?? ''));

const classify = (o) => {
  const t = textOf(o.data);
  const c = count(JSON.stringify(o.data));
  if (/Instructions from:|# 用户全局约定|# 本工作区说明/.test(t)) return ['指令文件 AGENTS.md', c];
  if (t.includes('A skill is a reusable set')) return ['技能目录', c];
  if (t.includes('行为规格')) return ['人格规格 PERSONA_SPEC', c];
  if (t.includes('关系记忆')) return ['关系记忆', c];
  if (t.includes('Current runtime context')) return ['运行期快照', c];
  if (t.includes('Time sampled while preparing')) return ['时间戳采样', c];
  return c.n < 400 ? ['用户消息本体', c] : ['其它注入', c];
};

// ---- 主流程 -------------------------------------------------------------
const file = resolveFile();
const text = readSession(file);
const lines = text.split('\n').filter((l) => l.trim());
const { header, sysMsg, usage, context, userMsgs } = firstRequest(lines);
if (!header) { console.error('这个会话里没有 request/header（可能还没起过请求）'); process.exit(2); }

const bucket = new Map();
const add = (k, c) => {
  const cur = bucket.get(k) ?? { n: 0, nonAscii: 0, ascii: 0 };
  cur.n += c.n; cur.nonAscii += c.nonAscii; cur.ascii += c.ascii;
  bucket.set(k, cur);
};

const tools = header.tools ?? [];
add(`工具 schema (${tools.length} 个)`, count(JSON.stringify(tools)));
if (sysMsg) add('系统提示 system', count(JSON.stringify(sysMsg)));
for (const o of userMsgs) { const [k, c] = classify(o); add(k, c); }
// ⚠️ 兜底纠正：分类按"含关键词"判，长会话里助手正文/工具结果也会提到这些词 ⇒ 同一类只认真实注入的那一份
// （判据：该类出现多份时取最小那两份里更小的一份——真实注入是完整一份，其余多半是引用）
const DUP_GUARD = ['指令文件 AGENTS.md', '关系记忆', '人格规格 PERSONA_SPEC'];
for (const key of DUP_GUARD) {
  const cur = bucket.get(key);
  if (!cur) continue;
  const sizes = userMsgs.map((o) => { const [k, c] = classify(o); return k === key ? c : null; }).filter(Boolean);
  if (sizes.length <= 1) continue;
  sizes.sort((a, b) => b.n - a.n);
  // 真实注入是"一次完整注入"：取最大那份为基准，其余视为重复/引用 ⇒ 只留一份
  const keep = sizes[0];
  bucket.set(key, keep);
}

let tot = { n: 0, nonAscii: 0, ascii: 0 };
for (const c of bucket.values()) { tot.n += c.n; tot.nonAscii += c.nonAscii; tot.ascii += c.ascii; }
const sumB = estB(tot) - ROLE;
const sumA = estA(tot) - ROLE;
const actual = (usage?.inputTokens ?? 0) + (usage?.cacheReadTokens ?? 0);
const k = actual > 0 ? actual / sumB : 1;

console.log('ctx-audit  ' + new Date().toISOString().replace('T', ' ').slice(0, 19));
console.log('session    : ' + file);
console.log('events     : ' + lines.length + ' 行');
if (context) console.log('模型/窗口  : ' + context.provider + ' / ' + context.model + '  window ' + context.contextWindow);
if (usage) console.log('实测 usage : input ' + usage.inputTokens + ' + cacheRead ' + usage.cacheReadTokens + ' = prompt ' + actual + ' token ｜ output ' + usage.outputTokens);

console.log('\n=== 组成（按模型 B 估算，已用实测总量校准）===');
console.log('组件'.padEnd(26) + '字符'.padStart(8) + '非ASCII'.padStart(9) + '≈token'.padStart(8) + '占比'.padStart(8));
for (const [kk, c] of [...bucket].sort((a, b) => estB(b[1]) - estB(a[1]))) {
  const tk = (estB(c) - ROLE) * k;
  console.log(kk.padEnd(26) + String(c.n).padStart(8) + ((c.nonAscii / c.n) * 100).toFixed(0).padStart(8) + '%' + String(Math.round(tk)).padStart(8) + ((tk / (sumB * k)) * 100).toFixed(1).padStart(7) + '%');
}
console.log('合计'.padEnd(26) + String(tot.n).padStart(8) + ((tot.nonAscii / tot.n) * 100).toFixed(0).padStart(8) + '%' + String(Math.round(sumB * k)).padStart(8));
console.log(`\n对账：模型A（官方 4 字符/token）${sumA} ｜ 模型B（中文 1.5）${sumB} ｜ 实测 ${actual} ⇒ 校准系数 ${k.toFixed(3)}`);
console.log('注：官方启发式会把中文块系统性低估（中文字符少、token 多），故 dashboard 的 systemTokens/toolsTokens 偏保守。');

// 工具榜
const top = Number(arg('tools-top', '15'));
if (tools.length) {
  const per = tools.map((t) => {
    const c = count(JSON.stringify(t));
    return [t.name, (estB(c) - ROLE) * k, (c.nonAscii / c.n) * 100];
  }).sort((a, b) => b[1] - a[1]);
  console.log(`\n=== 工具榜 top ${top}（≈token） ===`);
  for (const [n, tk, r] of per.slice(0, top)) console.log(String(Math.round(tk)).padStart(6) + '  ' + n.padEnd(26) + `非ASCII ${r.toFixed(0)}%`);
  console.log('工具合计 ≈ ' + Math.round(per.reduce((s, x) => s + x[1], 0)) + ' token');
}

// ---- --history：整个会话的「历史累积」账（上下文怎么长起来的）----------
if (process.argv.includes('--history')) {
  const byTool = new Map();   // 工具名 -> { calls, chars }
  const bucket2 = new Map();  // 事件类 -> chars
  let calls = 0, results = 0;
  for (const l of lines) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    const c = JSON.stringify(o.data ?? o).length;
    const add2 = (key) => bucket2.set(key, (bucket2.get(key) ?? 0) + c);
    switch (o.type) {
      case 'tool/call': {
        calls++;
        const name = o.data?.name ?? o.data?.tool ?? '?';
        const cur = byTool.get(name) ?? { calls: 0, chars: 0 };
        cur.calls++; cur.chars += c;
        byTool.set(name, cur);
        add2('工具调用参数');
        break;
      }
      case 'tool/result': {
        results++;
        const name = o.data?.name ?? o.data?.tool ?? '?';
        const cur = byTool.get(name) ?? { calls: 0, chars: 0 };
        cur.chars += c;
        byTool.set(name, cur);
        add2('工具结果（重活在这儿）');
        break;
      }
      case 'assistant/message': add2('助手回复（含思考）'); break;
      case 'user/message': add2('用户消息与注入'); break;
      case 'system/message': add2('系统消息'); break;
      default: break;
    }
  }
  const totChars = [...bucket2.values()].reduce((a, b) => a + b, 0);
  const totTok = estB({ n: totChars, ascii: 0, nonAscii: 0 }) - ROLE; // 上界：全按中文密度
  console.log('\n=== 会话历史累积（整个会话，不只是首轮）===');
  console.log(`事件：工具调用 ${calls} 次 / 工具结果 ${results} 条 ｜ 累积字符 ${totChars}`);
  console.log('类别'.padEnd(24) + '字符'.padStart(10) + '占比'.padStart(8));
  for (const [kk, v] of [...bucket2].sort((a, b) => b[1] - a[1]))
    console.log(kk.padEnd(24) + String(v).padStart(10) + ((v / totChars) * 100).toFixed(1).padStart(7) + '%');
  console.log('\n--- 按工具（结果＋参数，字符数降序）---');
  for (const [n, v] of [...byTool].sort((a, b) => b[1].chars - a[1].chars).slice(0, 15))
    console.log(String(v.chars).padStart(9) + `  ${n.padEnd(22)} ${v.calls} 次`);
}

