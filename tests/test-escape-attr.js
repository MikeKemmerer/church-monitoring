// Checks escapeAttr() from server/index.html: whatever a file or user name contains, placing it in
// onclick="f('...')" must hand exactly that text to f() and run nothing else.
//   node tests/test-escape-attr.js
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.html'), 'utf8');
const start = html.indexOf('function escapeAttr(');
const closing = /\n\}\r?\n/.exec(html.slice(start));
if (start < 0 || !closing) throw new Error('escapeAttr() not found in server/index.html');
const escapeAttr = new Function(html.slice(start, start + closing.index + closing[0].length) + '\nreturn escapeAttr;')();

const decode = (s) => s.replace(/&quot;/g, '"').replace(/&gt;/g, '>').replace(/&lt;/g, '<').replace(/&amp;/g, '&');

const samples = [
  "plain.png",
  "it's.png",
  "back\\slash.png",
  "ends-with-backslash\\",
  "\\');pwn();x=('",
  "');pwn();('",
  "\\\\');pwn();//",
  'quote"and<tag>&amp;.png',
  "line\nbreak\rreturn.png",
  "sep\u2028and\u2029para.png",
  "</script><img src=x onerror=pwn()>",
];

let failures = 0;
for (const sample of samples) {
  const attribute = `f('${escapeAttr(sample)}')`;
  let received = null;
  let pwned = false;
  try {
    new Function('f', 'pwn', decode(attribute))((v) => { received = v; }, () => { pwned = true; });
  } catch (err) {
    console.error(`FAIL ${JSON.stringify(sample)}: handler did not run (${err.message})`);
    failures++;
    continue;
  }
  if (pwned || received !== sample) {
    console.error(`FAIL ${JSON.stringify(sample)}: received ${JSON.stringify(received)}, injected=${pwned}`);
    failures++;
  }
  if (/["<>]/.test(escapeAttr(sample))) {
    console.error(`FAIL ${JSON.stringify(sample)}: raw quote or angle bracket survived in the attribute`);
    failures++;
  }
}
if (failures) process.exit(1);
console.log(`OK (${samples.length} names)`);
