// Write the `input` strings of test-cases.json one per line, for the Java probe
// (which reproduces findUrls() with the real androidx regex + java.net.URI).
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\//, ''));
const cases = JSON.parse(fs.readFileSync(path.join(here, 'test-cases.json'), 'utf8'));
const lines = cases.map((c) => {
  if (c.input.includes('\n')) throw new Error('case input contains a newline: ' + c.name);
  return c.input;
});
lines.push('@@END@@');
fs.writeFileSync(path.join(here, '_ref', 'case-inputs.txt'), lines.join('\n') + '\n', 'utf8');
console.log(`wrote ${cases.length} inputs to _ref/case-inputs.txt`);
