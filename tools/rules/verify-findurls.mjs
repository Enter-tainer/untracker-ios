#!/usr/bin/env node
// Diff an iOS (or any) link-detection result against the golden spans.
//
//   node verify-findurls.mjs --actual actual.json            # diff
//   node verify-findurls.mjs --actual actual.json --verbose  # + every case
//   node verify-findurls.mjs --self-check                    # validate the golden file
//
// ACTUAL file shapes accepted (all of these work):
//   {"cases": [{"name"?, "input": "...", "spans": [{"location":0,"length":5,"hasScheme":true,"url":"..."}]}]}
//   [{"name"?, "input": "...", "spans": [...]}, ...]
//   {"name"?, "input": "...", "spans": [...]}                  (single case)
// Cases are matched to the golden file by `name` when present, otherwise by exact `input`.
//
// Index unit: UTF-16 code units (Java String char offsets == NSString/NSRange offsets).
// `spans` must be the FINAL detected links in ascending, non-overlapping order; `url` is the
// string handed to the rules (matched text, with http:// prepended when no scheme was present,
// after java.net.URI.normalize()).
import fs from 'node:fs';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\//, ''));
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const has = (name) => args.includes(name);

const goldenPath = opt('--golden', path.join(HERE, 'findurls-cases.json'));
const actualPath = opt('--actual', null);
const verbose = has('--verbose');
const asJson = has('--json');
const selfCheck = has('--self-check');

const gold = JSON.parse(fs.readFileSync(goldenPath, 'utf8'));
const goldCases = Array.isArray(gold) ? gold : gold.cases;
if (!Array.isArray(goldCases)) {
  console.error(`bad golden file ${goldenPath}: expected {cases:[...]} or [...]`);
  process.exit(2);
}

const FIELDS = ['location', 'length', 'hasScheme', 'url'];
const show = (s) => JSON.stringify(s);
const spanLine = (s) =>
  `[${s.location},${s.length}${s.hasScheme === undefined ? '' : s.hasScheme ? ',S' : ',N'}]` +
  (s.url === undefined ? '' : ` ${show(s.url)}`);

// ------------------------------------------------------------------ self-check
function runSelfCheck() {
  let bad = 0;
  const fail = (m) => { bad++; console.error('FAIL: ' + m); };
  console.log(`self-check ${goldenPath}: ${goldCases.length} cases`);
  if (gold.indexUnit !== 'UTF-16 code units') fail('indexUnit must be "UTF-16 code units"');
  const names = new Set();
  let spans = 0;
  for (const c of goldCases) {
    if (typeof c.name !== 'string' || !c.name) fail('case without name');
    if (names.has(c.name)) fail(`duplicate case name ${c.name}`);
    names.add(c.name);
    if (typeof c.input !== 'string') fail(`${c.name}: input not a string`);
    if (!Array.isArray(c.spans)) fail(`${c.name}: spans not an array`);
    let prevEnd = -1;
    for (const s of c.spans || []) {
      spans++;
      if (!Number.isInteger(s.location) || !Number.isInteger(s.length)) fail(`${c.name}: non-integer span`);
      if (s.location < 0 || s.length < 0 || s.location + s.length > c.input.length) {
        fail(`${c.name}: span [${s.location},+${s.length}] outside input (len ${c.input.length})`);
      }
      if (s.location < prevEnd) fail(`${c.name}: spans overlap or out of order`);
      prevEnd = s.location + s.length;
      if (s.match !== undefined) {
        const slice = c.input.slice(s.location, s.location + s.length);
        if (slice !== s.match) fail(`${c.name}: input slice ${show(slice)} != match ${show(s.match)}`);
      }
      if (!/^https?:\/\//i.test(s.url || '')) fail(`${c.name}: url must start with http(s):// -> ${show(s.url)}`);
      if (s.hasScheme === true && !/^https?:\/\//i.test(s.url)) fail(`${c.name}: hasScheme but url has no scheme`);
      if (s.hasScheme === false && !s.url.startsWith('http://')) {
        fail(`${c.name}: scheme-less span must report the prepended http:// url -> ${show(s.url)}`);
      }
    }
  }
  if (bad) {
    console.error(`\n${bad} FAILURE(S)`);
    process.exit(1);
  }
  console.log(`OK: ${goldCases.length} cases, ${spans} spans, all invariants hold`);
}

// ------------------------------------------------------------------ diff
function normaliseActual(doc) {
  const list = Array.isArray(doc) ? doc : Array.isArray(doc.cases) ? doc.cases : [doc];
  return list.map((c, i) => {
    if (!c || typeof c.input !== 'string') throw new Error(`actual entry ${i} has no string 'input'`);
    return {
      name: c.name,
      input: c.input,
      spans: (c.spans || []).map((s) => ({
        location: s.location,
        length: s.length,
        hasScheme: s.hasScheme,
        url: s.url,
      })),
    };
  });
}

function diffSpans(input, expected, actual) {
  const problems = [];
  let firstBad = null;
  const n = Math.max(expected.length, actual.length);
  for (let i = 0; i < n; i++) {
    const e = expected[i];
    const a = actual[i];
    if (!e) { problems.push(`extra span #${i} in actual: ${spanLine(a)}`); continue; }
    if (!a) { problems.push(`missing span #${i} (expected ${spanLine(e)})`); continue; }
    let bad = false;
    for (const f of FIELDS) {
      if (f === 'hasScheme' && a.hasScheme === undefined) continue; // optional in actual
      if (e[f] !== a[f]) {
        problems.push(`span #${i} ${f}: expected ${show(e[f])}, actual ${show(a[f])}`);
        bad = true;
      }
    }
    if (bad && firstBad === null) firstBad = i;
  }
  if (firstBad !== null) {
    const e = expected[firstBad];
    const a = actual[firstBad];
    if (a && (e.location !== a.location || e.length !== a.length)) {
      problems.push(`span #${firstBad} text: expected ${show(input.slice(e.location, e.location + e.length))}, ` +
        `actual ${show(input.slice(a.location, a.location + a.length))}`);
    }
  }
  return problems;
}

function runDiff() {
  if (!actualPath) {
    console.error('usage: node verify-findurls.mjs --actual <json> [--golden <json>] [--verbose] [--json]');
    console.error('       node verify-findurls.mjs --self-check');
    process.exit(2);
  }
  const actual = normaliseActual(JSON.parse(fs.readFileSync(actualPath, 'utf8')));

  const byName = new Map(actual.filter((c) => c.name).map((c) => [c.name, c]));
  const byInput = new Map();
  for (const c of actual) if (!byInput.has(c.input)) byInput.set(c.input, c);

  const used = new Set();
  const results = [];
  for (const g of goldCases) {
    let a = byName.get(g.name);
    if (!a) a = byInput.get(g.input);
    if (a) used.add(a);
    const problems = a ? diffSpans(g.input, g.spans, a.spans) : [`missing from actual output (input ${show(g.input)})`];
    results.push({ name: g.name, input: g.input, expected: g.spans, actual: a ? a.spans : null, problems });
  }
  const extra = actual.filter((a) => !used.has(a));

  const failed = results.filter((r) => r.problems.length);
  const totalSpans = results.reduce((n, r) => n + r.expected.length, 0);

  if (asJson) {
    console.log(JSON.stringify({
      golden: goldenPath,
      actual: actualPath,
      cases: results.length,
      spans: totalSpans,
      passed: results.length - failed.length,
      failed: failed.length,
      failures: failed.map((r) => ({ name: r.name, input: r.input, problems: r.problems })),
      unmatchedActual: extra.map((a) => ({ name: a.name, input: a.input })),
    }, null, 2));
  } else {
    for (const r of results) {
      if (r.problems.length) {
        console.log(`\nFAIL ${r.name}`);
        console.log(`  input    ${show(r.input)}`);
        console.log(`  expected ${r.expected.map(spanLine).join(' | ') || '(no spans)'}`);
        console.log(`  actual   ${r.actual ? (r.actual.map(spanLine).join(' | ') || '(no spans)') : '(case not reported)'}`);
        for (const p of r.problems) console.log(`  - ${p}`);
      } else if (verbose) {
        console.log(`ok   ${r.name}  (${r.expected.map(spanLine).join(' | ') || 'no spans'})`);
      }
    }
    for (const a of extra) {
      console.log(`\nWARN actual reported a case that is not in the golden file: ${show(a.name || a.input)}`);
    }
    console.log(`\ncase matches: ${results.length - failed.length}/${results.length}, spans compared: ${totalSpans}`);
  }

  if (failed.length || extra.length) {
    if (!asJson) {
      console.error(`\n${failed.length} case(s) differ${extra.length ? `, ${extra.length} unmatched actual case(s)` : ''}`);
    }
    process.exit(1);
  }
  if (!asJson) console.log('ALL CASES MATCH THE GOLDEN SPANS');
}

if (selfCheck) runSelfCheck();
else runDiff();
