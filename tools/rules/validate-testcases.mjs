// Validate builtin-rules.json + test-cases.json.
//  - JSON parses, shape/types are right
//  - >= 40 test cases, unique names, ruleIds refer to existing rule ids
//  - >= 10 cases where nothing changes (expected === input)
//  - every rule script is syntactically valid JavaScript (parsed with new Function)
//  - coverage report: which rules are exercised by at least one case
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\//, ''));
const rulesPath = path.join(here, 'builtin-rules.json');
const casesPath = path.join(here, 'test-cases.json');

const rules = JSON.parse(fs.readFileSync(rulesPath, 'utf8'));
const cases = JSON.parse(fs.readFileSync(casesPath, 'utf8'));

let fail = 0;
const bad = (m) => { fail++; console.error('FAIL: ' + m); };

// ---- rules ---------------------------------------------------------------
if (!Array.isArray(rules)) bad('builtin-rules.json is not an array');
const ids = new Set();
for (const [i, r] of rules.entries()) {
  const keys = Object.keys(r).sort().join(',');
  if (keys !== 'description,enabled,id,name,script') bad(`rule ${i} keys = ${keys}`);
  if (typeof r.id !== 'string' || !r.id) bad(`rule ${i} bad id`);
  if (ids.has(r.id)) bad(`duplicate rule id ${r.id}`);
  ids.add(r.id);
  if (typeof r.script !== 'string' || !r.script.trim()) bad(`rule ${i} (${r.name}) empty script`);
  if (typeof r.enabled !== 'boolean') bad(`rule ${i} enabled not boolean`);
  try {
    // Rules are used as a function body: (function(url) { <script> })(url)
    // eslint-disable-next-line no-new-func
    new Function('url', r.script);
  } catch (e) {
    bad(`rule ${i} (${r.name}) script does not parse as JS: ${e.message}`);
  }
}

// ---- cases ---------------------------------------------------------------
if (!Array.isArray(cases)) bad('test-cases.json is not an array');
if (cases.length < 40) bad(`only ${cases.length} test cases, need >= 40`);

const names = new Set();
let noChange = 0;
let withRuleIds = 0;
const used = new Set();

for (const [i, c] of cases.entries()) {
  const where = `case ${i} (${c && c.name})`;
  for (const k of ['name', 'input', 'expected', 'note']) {
    if (typeof c[k] !== 'string') bad(`${where}: '${k}' missing or not a string`);
  }
  if (typeof c.name === 'string') {
    if (names.has(c.name)) bad(`${where}: duplicate name`);
    names.add(c.name);
  }
  if (c.ruleIds !== undefined) {
    withRuleIds++;
    if (!Array.isArray(c.ruleIds) || c.ruleIds.length === 0) bad(`${where}: ruleIds not a non-empty array`);
    for (const id of c.ruleIds) {
      if (!ids.has(id)) bad(`${where}: unknown rule id ${id}`);
      used.add(id);
    }
  } else {
    for (const r of rules) if (r.enabled) used.add(r.id);
  }
  if (c.expected === c.input) noChange++;
}

if (noChange < 10) bad(`only ${noChange} no-change cases, need >= 10`);

// ---- report --------------------------------------------------------------
console.log(`rules:      ${rules.length} (${rules.filter((r) => r.enabled).length} enabled)`);
console.log(`test cases: ${cases.length}, of which ${noChange} expect no change, ${withRuleIds} use ruleIds`);
console.log(`rule coverage: ${used.size}/${rules.length} rules appear in at least one case`);

const uncovered = rules.filter((r) => !used.has(r.id));
console.log('rules not exercised directly:', uncovered.length
  ? uncovered.map((r) => `${r.name}${r.enabled ? '' : ' [disabled]'}`).join(', ')
  : '(none)');
const disabled = rules.filter((r) => !r.enabled);
console.log('disabled upstream:', disabled.map((r) => `${r.name} ${r.id}`).join('; '));

if (fail) {
  console.error(`\n${fail} FAILURE(S)`);
  process.exit(1);
}
console.log('\nALL CHECKS PASSED');
