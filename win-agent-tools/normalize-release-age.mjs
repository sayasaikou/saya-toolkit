#!/usr/bin/env node
// normalize-release-age.mjs
//
// WHY THIS EXISTS (mechanism measured against pnpm 11.x, not guessed):
//   pnpm builds the minimumReleaseAge exemption through a policy evaluator that RETURNS
//   on the FIRST rule whose name matcher hits:
//
//       for (const { nameMatcher, exactVersions } of rules) {
//         if (!nameMatcher(pkgName)) continue;
//         if (exactVersions.length === 0) return true;
//         return exactVersions;          // <-- later rules for the SAME name are never read
//       }
//
//   So when one package name appears on several lines of minimumReleaseAgeExclude, only
//   the versions listed on the FIRST matching line are actually exempt. The rest LOOK
//   exempt in the file and are not -- and the failure surfaces somewhere else entirely,
//   which is what makes this worth a script.
//
//   Observed fallout: a lockfile pinned one version of a package whose exemption had been
//   written on three separate lines over time. Only the first line was honoured, so the
//   lockfile verifier rejected the already-installed version and every `pnpm install` /
//   `pnpm add` aborted with ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION -- even though the
//   exemption "was in the file". Appending a new line is the natural fix and it fails
//   silently, so the file has to be normalised instead.
//
// WHAT IT DOES: rewrites minimumReleaseAgeExclude so every package name has exactly ONE
//   rule carrying the union of all its versions (the shape pnpm actually honours).
//   Optionally merges extra specs in via --ensure. Idempotent.
//
// USAGE:
//   node normalize-release-age.mjs --file <pnpm-workspace.yaml> [--ensure "a@1.0.0,b@2.0.0"]
//                                  [--dry-run]
// Exit codes: 0 = ok (or nothing to change) | 1 = error

import fs from 'node:fs'
import path from 'node:path'

const argv = process.argv.slice(2)
function argOf(flag, dflt = null) {
  const i = argv.indexOf(flag)
  return i === -1 ? dflt : (argv[i + 1] ?? dflt)
}
const file = argOf('--file')
const ensureRaw = argOf('--ensure', '')
const dryRun = argv.includes('--dry-run')

if (!file) { console.error('usage: --file <pnpm-workspace.yaml> [--ensure a@1,b@2] [--dry-run]'); process.exit(1) }
if (!fs.existsSync(file)) { console.error('not found: ' + file); process.exit(1) }

const KEY = 'minimumReleaseAgeExclude'
const raw = fs.readFileSync(file, 'utf8')
const eol = raw.includes('\r\n') ? '\r\n' : '\n'
const lines = raw.split(/\r?\n/)

// ---- locate the block: from the KEY line up to the next top-level key (or EOF) ----
const startIdx = lines.findIndex((l) => l.trimEnd() === KEY + ':' || l.startsWith(KEY + ':'))
if (startIdx === -1) { console.log('no ' + KEY + ' block -- nothing to do'); process.exit(0) }

let endIdx = lines.length
for (let i = startIdx + 1; i < lines.length; i++) {
  const l = lines[i]
  if (l.trim() === '') continue
  if (/^\s*-\s+/.test(l) || /^\s*#/.test(l)) continue
  if (/^\S/.test(l)) { endIdx = i; break }   // next top-level key ends the block
}

// ---- parse entries: "- name@v1 || v2 || v3" (scoped names may be quoted) ----
function parseEntry(text) {
  let t = text.trim()
  if ((t.startsWith("'") && t.endsWith("'")) || (t.startsWith('"') && t.endsWith('"'))) t = t.slice(1, -1)
  const at = t.startsWith('@') ? t.indexOf('@', 1) : t.indexOf('@')
  if (at === -1) return { name: t, versions: [] }
  const name = t.slice(0, at)
  const versions = t.slice(at + 1).split('||').map((v) => v.trim()).filter(Boolean)
  return { name, versions }
}

const order = []
const byName = new Map()
for (let i = startIdx + 1; i < endIdx; i++) {
  const m = lines[i].match(/^\s*-\s+(.+?)\s*$/)
  if (!m) continue
  const { name, versions } = parseEntry(m[1])
  if (!byName.has(name)) { byName.set(name, new Set()); order.push(name) }
  for (const v of versions) byName.get(name).add(v)
}
const linesBefore = order.length

// ---- merge in the specs we are asked to guarantee ----
const ensured = []
for (const spec of ensureRaw.split(',').map((s) => s.trim()).filter(Boolean)) {
  const { name, versions } = parseEntry(spec)
  if (!versions.length) continue
  if (!byName.has(name)) { byName.set(name, new Set()); order.push(name) }
  for (const v of versions) {
    if (!byName.get(name).has(v)) { byName.get(name).add(v); ensured.push(name + '@' + v) }
  }
}

// ---- rebuild ----
function cmpVersion(a, b) {
  const pa = a.split('.'), pb = b.split('.')
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const xa = pa[i], xb = pb[i]
    if (xa === undefined) return -1
    if (xb === undefined) return 1
    const na = Number(xa), nb = Number(xb)
    if (Number.isFinite(na) && Number.isFinite(nb)) { if (na !== nb) return na - nb; continue }
    const c = xa.localeCompare(xb)
    if (c !== 0) return c
  }
  return 0
}
const newBlock = [KEY + ':']
let packages = 0
for (const name of order) {
  const versions = [...byName.get(name)].sort(cmpVersion)
  if (!versions.length) { newBlock.push('  - ' + (name.startsWith('@') ? `'${name}'` : name)); packages++; continue }
  const spec = name + '@' + versions.join(' || ')
  newBlock.push('  - ' + (name.startsWith('@') ? `'${spec}'` : spec))
  packages++
}

const newLines = [...lines.slice(0, startIdx), ...newBlock, ...lines.slice(endIdx)]
const out = newLines.join(eol)
const before = linesBefore
const after = packages

if (out === raw) {
  console.log(`unchanged: ${packages} package rule(s), ${ensured.length} version(s) merged`)
  process.exit(0)
}
if (dryRun) {
  console.log(`DRY-RUN: ${before} line(s) -> ${after} rule(s); would merge ${ensured.length} version(s)`)
  process.exit(0)
}

const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 13)
const bak = file + '.bak-' + stamp
fs.copyFileSync(file, bak)
// keep bytes ASCII (no BOM), same line endings as the original
fs.writeFileSync(file, out, 'utf8')
// read back: "writeFileSync did not throw" is not proof the file on disk matches
const back = fs.readFileSync(file, 'utf8')
if (back !== out) { console.error('READBACK MISMATCH -- restoring from ' + bak); fs.copyFileSync(bak, file); process.exit(1) }
console.log(`ok: ${before} line(s) -> ${after} rule(s); merged ${ensured.length} version(s)${ensured.length ? ' [' + ensured.join(', ') + ']' : ''}`)
console.log('backup: ' + bak)
