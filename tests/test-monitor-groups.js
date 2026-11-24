// Exercise actual dashboard functions with offline grouped/legacy fixtures.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const html = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.html'), 'utf8');
const context = vm.createContext({});
for (const name of ['statusClass', 'monitorSeverityRank', 'monitorGroupSummary',
    'rememberMonitorGroup', 'renderMonitorService', 'renderMonitorServices', 'hostHealth',
    'escapeHtml', 'escapeAttr']) {
    const start = html.indexOf(`function ${name}(`);
    const end = /\n\}\r?\n/.exec(html.slice(start));
    assert(start >= 0 && end, `${name} exists`);
    vm.runInContext(html.slice(start, start + end.index + end[0].length), context);
}
vm.runInContext('var monitorGroupExpansion = Object.create(null);', context);
const leaf = (name, status, severity) => ({name, type:'process', status, severity});
const group = {name:'workers', label:'Workers', type:'group', severity:'ok',
    children:[leaf('early-warning', 'starting', 'warning'), leaf('failed-worker', 'failed', 'error')]};
const health = (services, extra = {}) => context.hostHealth({services, ...extra});
assert.equal(health([leaf('apache', 'active')]), 'ok');
assert.equal(health([leaf('apache', 'inactive')]), 'warn');
assert.equal(health([group]), 'err');
assert.equal(context.monitorSeverityRank('__proto__'), 1);
assert.equal(health([leaf('flat', 'active'), group], {bluetooth_hid:{status:'waiting'}}), 'err');
const pair = (a, b, browser = 'browser') => [leaf('vlc', a), leaf(browser, b)];
for (const browser of ['browser', 'midori']) {
    assert.equal(health(pair('running (1)', 'not running', browser)), 'ok');
    assert.equal(health(pair('not running', 'running (1)', browser)), 'ok');
    assert.equal(health(pair('running (1)', 'running (1)', browser)), 'warn');
    assert.equal(health(pair('not running', 'not running', browser)), 'warn');
    assert.equal(health([...pair('running (1)', 'running (1)', browser), group]), 'err');
}
assert.equal(context.monitorGroupSummary(group).reason, 'failed-worker: failed');
assert.equal(health([{...group, severity:'error', reason:'Invalid configuration', children:[]}]), 'err');
assert.equal(health([{...group, severity:'unknown', children:[]}]), 'warn');
assert.equal(health([{...group, children:[leaf('a', 'active', 'ok')]}]), 'ok');
assert.equal(health([{...group, children:[leaf('a', 'starting', 'warning')]}]), 'warn');
assert.equal(context.monitorGroupSummary({...group, severity:'error', reason:'Provider error',
    children:[leaf('a', 'active', 'ok')]}).reason, 'Provider error');
assert.equal(context.monitorGroupSummary({...group, children:[
    leaf('first', 'failed', 'error'), leaf('second', 'failed', 'error')]}).reason, 'first: failed');
let rendered = context.renderMonitorServices('host', [leaf('flat', 'active'), group]);
assert(rendered.includes('<summary>') && rendered.includes('failed-worker: failed'));
assert(!rendered.includes(' open'));
context.rememberMonitorGroup('host', 'workers', true);
assert(context.renderMonitorServices('host', [group]).includes(' open'));
assert(!context.renderMonitorServices('other-host', [group]).includes(' open'));
assert.equal(health([group]), 'err');
context.rememberMonitorGroup('host', 'workers', false);
assert(!context.renderMonitorServices('host', [group]).includes(' open'));
const malicious = `\\');pwn();('"<img src=x onerror=pwn()>&\n`;
const evil = {...group, name:malicious, label:malicious,
    children:[{...leaf(malicious, malicious, 'error'), reason:malicious, type:malicious}]};
rendered = context.renderMonitorServices(malicious, [evil]);
assert(!rendered.includes('<img'));
assert(rendered.includes('&lt;img'));
const handler = /ontoggle="([^"]*)"/.exec(rendered)[1]
    .replace(/&quot;/g, '"').replace(/&gt;/g, '>').replace(/&lt;/g, '<').replace(/&amp;/g, '&');
let received;
new Function('rememberMonitorGroup', 'pwn', handler).call({open:true},
    (...args) => { received = args; }, () => { throw Error('injection'); });
assert.deepEqual(received, [malicious, malicious, true]);
assert(context.renderMonitorServices('__proto__', [{...group, name:'__proto__'}]).includes('<summary>'));
console.log('OK monitor group rendering, health, expansion, escaping and kiosk fixtures');
