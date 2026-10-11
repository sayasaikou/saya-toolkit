// ctx-audit -- measure what one real request is actually made of
//
// WHAT IT READS (and why each source is trusted or not):
//   * request/header.tools  = the exact tool schemas the host sent to the provider.
//                             Byte-exact; no estimation involved.
//   * prompt total          = the provider-reported usage (inputTokens + cacheReadTokens).
//   * per-block shares      = two density models, because a tokenizer is not available here:
//                             A = the host token-meter heuristic (~4 chars per token),
//                             B = CJK at 1.5 chars/token and ASCII at 4.
//                             After calibrating against the measured total, the two usually
//                             land within 10% of each other. Density is a heuristic, NOT
//                             tokenizer truth -- cross-check with the host context panel.
//
// WHY THE CALIBRATION FACTOR EXISTS:
//   The official heuristic systematically UNDERCOUNTS CJK blocks (fewer characters, more
//   tokens each), so a raw character-based estimate is biased low on exactly the blocks
//   worth measuring. Calibrating against the provider usage removes most of that bias.
//
// USAGE:
//   node ctx-audit.mjs                       # newest session
//   node ctx-audit.mjs --session <id>        # a specific session
//   node ctx-audit.mjs --file <path.jsonl>   # an already-decompressed jsonl
//   node ctx-audit.mjs --tools-top 25        # tool leaderboard length (default 15)
//   node ctx-audit.mjs --history             # the whole-session accumulation account
//
// Exit codes: 0 = reported | 2 = no request/header in that session | 1 = error
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const ROOT = process.env.DSH_HOME ?? join(process.env.USERPROFILE ?? '', '.dsh');
const SESSIONS = join(ROOT, 'sessions');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i === -1 ? dflt : process.argv[i + 1];
}

// ---- locate the log file ----
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
    if (!f) throw new Error('session not found: ' + want);
    return f;
  }
  return newestSessionFile();
}

// ---- multi-frame zstd decompression ----
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
    catch { /* trailing partial frame, ignore */ }
  }
  return Buffer.concat(chunks).toString('utf8');
}

// ---- split out one request ----
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
  if (/Instructions from:|# Workspace Instructions|# Global Instructions/.test(t)) return ['instruction files (AGENTS.md)', c];
  if (t.includes('A skill is a reusable set')) return ['skill catalog', c];
  if (/^#\\s*Persona|PERSONA_SPEC/.test(t)) return ['persona spec', c];
  if (t.includes('relationship memory')) return ['relationship memory', c];
  if (t.includes('Current runtime context')) return ['runtime snapshot', c];
  if (t.includes('Time sampled while preparing')) return ['clock sample', c];
  return c.n < 400 ? ['user message body', c] : ['other injection', c];
};

// ---- main ----
const file = resolveFile();
const text = readSession(file);
const lines = text.split('\n').filter((l) => l.trim());
const { header, sysMsg, usage, context, userMsgs } = firstRequest(lines);
if (!header) { console.error('no request/header in this session (no request issued yet?)'); process.exit(2); }

const bucket = new Map();
const add = (k, c) => {
  const cur = bucket.get(k) ?? { n: 0, nonAscii: 0, ascii: 0 };
  cur.n += c.n; cur.nonAscii += c.nonAscii; cur.ascii += c.ascii;
  bucket.set(k, cur);
};

const tools = header.tools ?? [];

if (sysMsg) add('system prompt', count(JSON.stringify(sysMsg)));
for (const o of userMsgs) { const [k, c] = classify(o); add(k, c); }


const DUP_GUARD = ['instruction files (AGENTS.md)', 'relationship memory', 'persona spec'];
for (const key of DUP_GUARD) {
  const cur = bucket.get(key);
  if (!cur) continue;
  const sizes = userMsgs.map((o) => { const [k, c] = classify(o); return k === key ? c : null; }).filter(Boolean);
  if (sizes.length <= 1) continue;
  sizes.sort((a, b) => b.n - a.n);

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
console.log('events     : ' + lines.length + ' lines');
if (context) console.log('model/window: ' + context.provider + ' / ' + context.model + '  window ' + context.contextWindow);
if (usage) console.log('measured usage: input ' + usage.inputTokens + ' + cacheRead ' + usage.cacheReadTokens + ' = prompt ' + actual + ' token ｜ output ' + usage.outputTokens);



for (const [kk, c] of [...bucket].sort((a, b) => estB(b[1]) - estB(a[1]))) {
  const tk = (estB(c) - ROLE) * k;
  console.log(kk.padEnd(26) + String(c.n).padStart(8) + ((c.nonAscii / c.n) * 100).toFixed(0).padStart(8) + '%' + String(Math.round(tk)).padStart(8) + ((tk / (sumB * k)) * 100).toFixed(1).padStart(7) + '%');
}
console.log('total'.padEnd(26) + String(tot.n).padStart(8) + ((tot.nonAscii / tot.n) * 100).toFixed(0).padStart(8) + '%' + String(Math.round(sumB * k)).padStart(8));

console.log('note: the official heuristic undercounts CJK blocks, so its systemTokens/toolsTokens read low on CJK-heavy prompts.');

// tool leaderboard
const top = Number(arg('tools-top', '15'));
if (tools.length) {
  const per = tools.map((t) => {
    const c = count(JSON.stringify(t));
    return [t.name, (estB(c) - ROLE) * k, (c.nonAscii / c.n) * 100];
  }).sort((a, b) => b[1] - a[1]);

  for (const [n, tk, r] of per.slice(0, top)) console.log(String(Math.round(tk)).padStart(6) + '  ' + n.padEnd(26) + `non-ASCII ${r.toFixed(0)}%`);
  console.log('tools total ~ ' + Math.round(per.reduce((s, x) => s + x[1], 0)) + ' token');
}

// ---- --history: how the context grew over the whole session ----
if (process.argv.includes('--history')) {


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
        add2('tool call arguments');
        break;
      }
      case 'tool/result': {
        results++;
        const name = o.data?.name ?? o.data?.tool ?? '?';
        const cur = byTool.get(name) ?? { calls: 0, chars: 0 };
        cur.chars += c;
        byTool.set(name, cur);
        add2('tool results (the bulk)');
        break;
      }
      case 'assistant/message': add2('assistant replies (incl. thinking)'); break;
      case 'user/message': add2('user messages and injections'); break;
      case 'system/message': add2('system messages'); break;
      default: break;
    }
  }
  const totChars = [...bucket2.values()].reduce((a, b) => a + b, 0);


  console.log(`events: tool calls ${calls} / tool results ${results} | accumulated chars ${totChars}`);
  console.log('category'.padEnd(24) + 'chars'.padStart(10) + 'share'.padStart(8));
  for (const [kk, v] of [...bucket2].sort((a, b) => b[1] - a[1]))
    console.log(kk.padEnd(24) + String(v).padStart(10) + ((v / totChars) * 100).toFixed(1).padStart(7) + '%');
  console.log('\n--- per tool (results + arguments, char count desc) ---');
  for (const [n, v] of [...byTool].sort((a, b) => b[1].chars - a[1].chars).slice(0, 15))
    console.log(String(v.chars).padStart(9) + `  ${n.padEnd(22)} ${v.calls} calls`);
}
