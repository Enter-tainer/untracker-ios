// Extract every Rule(...) from BuiltinRuleList.kt into builtin-rules.json.
// The script text is the value of the Kotlin raw string. Kotlin raw strings are
// literal except for trimIndent(), which is applied when present.
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\//, ''));
const srcPath = process.argv[2] || path.join(here, '_ref', 'BuiltinRuleList.kt');
const outPath = process.argv[3] || path.join(here, 'builtin-rules.json');

let src = fs.readFileSync(srcPath, 'utf8');
if (src.includes('\r')) throw new Error('source contains CR; refusing to guess line endings');
src = src.replace(/^\uFEFF/, '');

// Kotlin String.trimIndent(): drop first line if blank, drop last line if blank,
// remove the minimal indent of all non-blank lines. Blank lines become empty.
function trimIndent(s) {
  let lines = s.split('\n');
  if (lines.length && lines[0].trim() === '') lines = lines.slice(1);
  if (lines.length && lines[lines.length - 1].trim() === '') lines = lines.slice(0, -1);
  const indents = lines
    .filter((l) => l.trim() !== '')
    .map((l) => l.length - l.replace(/^[ \t]+/, '').length);
  const min = indents.length ? Math.min(...indents) : 0;
  return lines
    .map((l) => (l.trim() === '' ? '' : l.slice(min)))
    .join('\n');
}

// Split the file into Rule blocks. Scripts never contain the token "Rule(".
const starts = [];
const reRule = /\bRule\(/g;
let m;
while ((m = reRule.exec(src)) !== null) starts.push(m.index);
if (!starts.length) throw new Error('no Rule( found');

const rules = [];
for (let i = 0; i < starts.length; i++) {
  const block = src.slice(starts[i], i + 1 < starts.length ? starts[i + 1] : src.length);

  const id = /id\s*=\s*"([^"]*)"/.exec(block);
  const name = /name\s*=\s*"([^"]*)"/.exec(block);
  const description = /description\s*=\s*"([^"]*)"/.exec(block);
  if (!id || !name || !description) throw new Error(`missing field in block ${i}`);
  const enabled = !/enabled\s*=\s*false\b/.test(block);

  // script = """...""" [.trimIndent()]
  const scriptStart = block.indexOf('script');
  if (scriptStart < 0) throw new Error(`missing script in block ${i}`);
  const open = block.indexOf('"""', scriptStart);
  if (open < 0) throw new Error(`missing raw-string open in block ${i}`);
  const close = block.indexOf('"""', open + 3);
  if (close < 0) throw new Error(`missing raw-string close in block ${i}`);
  const raw = block.slice(open + 3, close);
  const after = block.slice(close + 3);
  const trims = /^\s*\.trimIndent\s*\(/.test(after);

  rules.push({
    id: id[1],
    name: name[1],
    description: description[1],
    script: trims ? trimIndent(raw) : raw,
    enabled,
    // not emitted, used by the verifier:
    _raw: raw,
    _trimmed: trims,
  });
}

// Sanity: ids unique.
const seen = new Set();
for (const r of rules) {
  if (seen.has(r.id)) throw new Error('duplicate id ' + r.id);
  seen.add(r.id);
}

const out = rules.map(({ id, name, description, script, enabled }) => ({
  id,
  name,
  description,
  script,
  enabled,
}));
fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n', 'utf8');
console.log(`wrote ${out.length} rules to ${outPath}`);
console.log('enabled:', out.filter((r) => r.enabled).length, 'disabled:', out.filter((r) => !r.enabled).length);
console.log('disabled ids:', out.filter((r) => !r.enabled).map((r) => r.name).join(', '));
console.log('single-line scripts (no trimIndent):', rules.filter((r) => !r._trimmed).map((r) => r.name).join(', '));
