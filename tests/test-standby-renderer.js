const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const html = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.html'), 'utf8');
let contributor = false;
const context = vm.createContext({hasRole: () => contributor, Date, Number});
for (const name of ['renderStandbyRow', 'renderStandbySettings', 'renderMenu', 'escapeHtml', 'escapeAttr']) {
    const start = html.indexOf(`function ${name}(`);
    const end = /\n\}\r?\n/.exec(html.slice(start));
    assert(start >= 0 && end, name);
    vm.runInContext(html.slice(start, start + end.index + end[0].length), context);
}
const state = {settings_version:1, default_minutes:90, state:'idle', updated_epoch:Math.floor(Date.now()/1000)};
let rendered = context.renderStandbySettings('host', state);
assert(rendered.includes('90 min from failover start'));
assert(!rendered.includes('<input') && !rendered.includes('Save default'));
contributor = true;
for (const status of ['idle', 'fired', 'disabled', 'stale']) {
    rendered = context.renderStandbySettings('host', {...state, state:status});
    assert(rendered.includes('Save default') && !rendered.includes('type="checkbox"'));
    assert(!context.renderStandbyRow('host', {...state, state:status}).includes('standby-settings'));
}
const counting = {...state, state:'counting', deadline:Date.now()/1000 + 600};
rendered = context.renderStandbySettings("host'\"<>&", counting);
assert(rendered.includes('Apply to current countdown'));
assert(rendered.includes('total time since failover began, not time remaining'));
assert(!rendered.includes("host'\"<>&"));
assert(!context.renderStandbySettings('host', {...state, state:'counting', deadline:1}).includes('type="checkbox"'));
assert(!context.renderStandbySettings('host', {...state, state:'counting', deadline:Date.now()/1000+600,
    updated_epoch:Date.now()/1000-300}).includes('type="checkbox"'));
assert(context.renderStandbySettings('host', {state:'idle'}).includes('require an updated videokiosk2'));
assert(!context.renderStandbySettings('host', {state:'idle'}).includes('Save default'));
assert(context.renderStandbySettings('host', {...state, default_minutes:0}).includes('disabled in legacy'));
assert(!context.renderStandbySettings('host', {...state, default_minutes:'<script>evil()</script>'}).includes('<script>'));
const menu = context.renderMenu('host', {services:[], display_control:{label:'TV + HDMI'}, standby_timer:counting});
assert(menu.includes('TV + HDMI') && menu.includes('standby-settings') && menu.includes('Save default'));
assert(menu.indexOf('id="sub-display-') < menu.indexOf('class="standby-settings"'));
assert(menu.includes('class="standby-settings" onclick="event.stopPropagation()"'));
rendered = context.renderStandbyRow('host', counting);
assert(rendered.includes('standby-left') && rendered.includes('standby-minus'));
assert(!rendered.includes('standby-settings') && !rendered.includes('Future countdowns'));
assert(!context.renderStandbySettings('host', null));
console.log('OK standby settings in display menu only, current countdown, roles and escaping');
