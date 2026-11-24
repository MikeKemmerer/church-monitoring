const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const html = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.html'), 'utf8');
const context = vm.createContext({URL});
for (const name of ['statusClass','monitorSeverityRank','monitorGroupSummary','rememberMonitorGroup',
    'renderMonitorService','renderMonitorServices','streamingPageUrl','escapeHtml','escapeAttr']) {
    const start = html.indexOf(`function ${name}(`);
    const end = /\n\}\r?\n/.exec(html.slice(start));
    assert(start >= 0 && end, name);
    vm.runInContext(html.slice(start, start + end.index + end[0].length), context);
}
vm.runInContext('var monitorGroupExpansion = Object.create(null);', context);
const children = ['Playback','Encoder','Media storage','Scheduling'].map((label, index) => ({
    name: 'streaming-' + index, label, type:'info', severity:index === 2 ? 'unknown' : 'warning',
    status:index === 2 ? 'unknown' : 'warning', reason:'<img src=x onerror=evil()>',
    observed_at:'2026-11-24T18:00:00Z', age_seconds:12,
    details:{current_title:'<script>evil()</script>', encoder_pid:123, token:'SECRET'}
}));
children[3].source_observations = {
    scheduling:{observed_at:'2026-11-24T18:00:00Z', age_seconds:12, reason:'Discovery fresh'},
    services:{observed_at:'2026-11-24T17:57:00Z', age_seconds:192, reason:'Stale <script>evil()</script>'}
};
const group = {name:'streaming', type:'group', provider:'yt-streamer', severity:'warning', children,
    label:'Streaming',
    next_action:{action:'unknown-SECRET', at:'<script>evil()</script>'},
    ui_url:'https://streaming.example.org/'};
const summary = context.monitorGroupSummary(group);
assert.equal(summary.severity, 'warning');
assert.equal(summary.uncertainty_count, 1);
assert(summary.reason.includes('1 uncertain row'));
let rendered = context.renderMonitorServices('host', [group]);
assert(rendered.includes('Streaming'));
assert(rendered.includes('Open streaming service') && rendered.includes('noopener noreferrer'));
assert(!rendered.includes('<details') && !rendered.includes('<summary'));
assert.equal((rendered.match(/class="svc-row"/g) || []).length, 1);
assert(rendered.includes('1 uncertain row'));
assert(!rendered.includes('SECRET') && !rendered.includes('encoder pid'));
assert(!rendered.includes('<script>') && !rendered.includes('<img'));
assert(!rendered.includes('&lt;script&gt;') && !rendered.includes('Age:'));
assert(!rendered.includes('Control services observed:') && !rendered.includes('2026-11-24'));
assert(!rendered.includes('current title') && !rendered.includes('next action'));
assert(!rendered.includes('restart'));
for (const url of ['javascript:evil()', 'http://user:pass@host/', 'http://host/?token=SECRET',
    'http://host/"x', 'http://host/\\evil', 'http://host/#secret']) {
    assert(!context.renderMonitorServices('host', [{...group, ui_url:url}]).includes('Open streaming service'));
}
assert(!context.renderMonitorServices('host', [{...group, ui_url:null}]).includes('Open streaming service'));
context.rememberMonitorGroup('host', 'streaming', true);
assert(!context.renderMonitorServices('host', [group]).includes(' open'));
const failing = {...group, children:[{...children[0], label:'Encoder', severity:'error', reason:'Encoder stalled'}]};
assert(context.renderMonitorServices('host', [failing]).includes('Encoder: Encoder stalled'));
console.log('OK top-level streaming summary, uncertainty, service link and escaping');
