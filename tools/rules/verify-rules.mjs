// Verify builtin-rules.json against the upstream Kotlin source.
//   1. rule count == number of `Rule(` tokens == number of `id = "..."` fields
//   2. every script, re-read from JSON, equals the raw-string content of the .kt
//      (after String.trimIndent() when the literal calls it)
//   3. every script occurs VERBATIM inside BuiltinRuleList.kt once its original
//      block indent is put back on each line
//   4. ids are unique UUIDs, fields have the expected types
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\//, ''));
const srcPath = process.argv[2];
if (!srcPath) {
  console.error('usage: node ' + path.basename(process.argv[1]) + ' <path to upstream BuiltinRuleList.kt> [output.json]');
  process.exit(2);
}
const jsonPath = process.argv[3] || path.join(here, 'builtin-rules.json');

const src = fs.readFileSync(srcPath, 'utf8').replace(/^\uFEFF/, '');
const rules = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));

let failures = 0;
function check(cond, msg) {
  if (!cond) {
    failures++;
    console.error('FAIL: ' + msg);
  }
}

// ---- 1. counts ------------------------------------------------------------
const ruleTokens = (src.match(/\bRule\(/g) || []).length;
const idFields = (src.match(/^\s*id\s*=\s*"[0-9a-f-]{36}",?\s*$/gm) || []).length;
check(Array.isArray(rules), 'JSON root must be an array');
check(rules.length === ruleTokens, `rule count ${rules.length} != Rule( tokens ${ruleTokens}`);
check(rules.length === idFields, `rule count ${rules.length} != id fields ${idFields}`);

// ---- 2. independent re-extraction ----------------------------------------
function trimIndent(lines) {
  let l = lines.slice();
  if (l.length && l[0].trim() === '') l.shift();
  if (l.length && l[l.length - 1].trim() === '') l.pop();
  const indents = l.filter((x) => x.trim() !== '').map((x) => x.match(/^[ \t]*/)[0].length);
  const min = indents.length ? Math.min(...indents) : 0;
  return l.map((x) => (x.trim() === '' ? '' : x.slice(min))).join('\n');
}

// Walk the source and capture each `script = """` literal as [rawText, blockIndent, usesTrimIndent]
const literals = [];
{
  const re = /script\s*=\s*\n?([ \t]*)"""/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const openEnd = m.index + m[0].length;
    const close = src.indexOf('"""', openEnd);
    if (close < 0) throw new Error('unterminated raw string');
    const raw = src.slice(openEnd, close);
    const after = src.slice(close + 3, close + 200);
    const usesTrim = /^\s*\.trimIndent\s*\(/.test(after);
    literals.push({ raw, usesTrim, at: m.index });
  }
}
check(literals.length === rules.length, `found ${literals.length} script literals, ${rules.length} rules in JSON`);

// Line indentation of a raw literal: the indent that every line shares.
function blockIndent(raw) {
  const lines = raw.split('\n').slice(1); // first line is empty (after """), ignore it
  const ind = lines.filter((x) => x.trim() !== '').map((x) => x.match(/^[ \t]*/)[0].length);
  return ind.length ? Math.min(...ind) : 0;
}

const seenIds = new Set();
for (let i = 0; i < rules.length; i++) {
  const r = rules[i];
  const lit = literals[i];
  const expected = lit.usesTrim ? trimIndent(lit.raw.split('\n')) : lit.raw;

  // field shape
  check(JSON.stringify(Object.keys(r)) === JSON.stringify(['id', 'name', 'description', 'script', 'enabled']),
    `rule ${i} (${r.id}) keys are ${Object.keys(r)}`);
  check(typeof r.id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(r.id),
    `rule ${i} id not a uuid: ${r.id}`);
  check(!seenIds.has(r.id), `duplicate id ${r.id}`);
  seenIds.add(r.id);
  check(typeof r.name === 'string' && r.name.length > 0, `rule ${i} bad name`);
  check(typeof r.description === 'string', `rule ${i} bad description`);
  check(typeof r.script === 'string' && r.script.length > 0, `rule ${i} bad script`);
  check(typeof r.enabled === 'boolean', `rule ${i} enabled not boolean`);

  // 2. byte-exact
  check(r.script === expected,
    `rule ${i} (${r.name}) script mismatch\n--- JSON ---\n${JSON.stringify(r.script)}\n--- KT ---\n${JSON.stringify(expected)}`);

  // 3. verbatim occurrence with block indent restored
  const ind = lit.usesTrim ? blockIndent(lit.raw) : 0;
  const reindented = r.script.split('\n').map((l) => (l === '' ? l : ' '.repeat(ind) + l)).join('\n');
  check(src.includes(reindented), `rule ${i} (${r.name}) script does not occur verbatim in the .kt (indent ${ind})`);
}

// ---- 4. spot-check semantics of the trimIndent implementation -------------
{
  const ktTrim = trimIndent(['', '    a', '      b', ''].slice(0, 3));
  check(ktTrim === 'a\n  b', `trimIndent self-test wrong: ${JSON.stringify(ktTrim)}`);
}

const enabled = rules.filter((r) => r.enabled).length;
console.log(`checked ${rules.length} rules: ${enabled} enabled, ${rules.length - enabled} disabled`);
console.log('disabled:', rules.filter((r) => !r.enabled).map((r) => r.name).join(', '));
console.log('ids:', rules.map((r) => r.id.slice(0, 8)).join(' '));
if (failures) {
  console.error(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log('\nALL CHECKS PASSED (count, byte-exact scripts, verbatim occurrence, field shape)');
