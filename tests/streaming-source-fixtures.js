// Optional read-only reference verification; evaluate only the pure source builder.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
if (!process.argv[2]) throw Error('Pass the authorized streamer checkout path');
const source = fs.readFileSync(path.join(process.argv[2], 'web', 'backend', 'server.js'), 'utf8');
const start = source.indexOf('function buildDiagnostics(');
const end = source.indexOf('\nlet diagnosticProbes', start);
if (start < 0 || end < 0) throw Error('Diagnostics builder not found');
const build = vm.runInNewContext('(' + source.slice(start, end).trim() + ')');
const now = 1795543200;
const inputs = (mode, scheduleSource, provider) => ({
    player:{state:'inactive', active:false, playbackHealth:{status:'unknown'}},
    youtube:{provider, fresh:scheduleSource === 'youtube', ageSeconds:scheduleSource === 'youtube' ? 0 : null,
        events:[], sync:null, control:{}},
    state:scheduleSource === 'youtube' ? {decision:{command:'IDLE', observedAt:now}} : {},
    weekly:scheduleSource === 'weekly' ? {expected:'stopped', reason:'Weekly window closed', observedAt:now} : null,
    probes:{observed_at:now, storage:{severity:'ok',reason:'Recording read succeeded',available_count:4,
        saved_enabled_count:0,selection_source:'directory_scan'},
        auth:{severity:'ok',reason:'Managed authentication; no SAS expiry',mode:'msi'},
        resources:{severity:'ok',reason:'Host metrics available'},
        services:Object.fromEntries(['scheduler.service','web-backend.service','caddy.service',
            'youtube-sync.timer','schedule-sync.timer','mnt-blobfuse2.mount'].map(unit => [unit,{state:'active',restarts:0}]))},
    mode, source:scheduleSource, calendarRequired:false, studioConfirmed:true
});
const fixtures = [];
for (const [mode, scheduleSource, provider] of [
    ['local','weekly','api'], ['azure','weekly','api'], ['local','youtube','api'], ['local','youtube','yt-dlp']
]) {
    fixtures.push({name:[mode,scheduleSource,provider].join('-'),payload:build(inputs(mode,scheduleSource,provider),now)});
}
const missingCalendar = inputs('local', 'youtube', 'yt-dlp');
missingCalendar.calendarRequired = true;
fixtures.push({name:'local-youtube-missing-calendar', expected_severity:'unknown', payload:build(missingCalendar,now)});
const staleDecision = inputs('local', 'youtube', 'api');
staleDecision.state.decision.observedAt = now - 91;
fixtures.push({name:'local-youtube-stale-decision', expected_severity:'unknown', payload:build(staleDecision,now)});
process.stdout.write(JSON.stringify({now,fixtures}));
