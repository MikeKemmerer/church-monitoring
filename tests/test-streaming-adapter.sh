#!/usr/bin/env bash
# Real status CGI/CLI assembly, restart authorization and display-only digest.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.test-streaming-adapter-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
export ROOT WORK PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import datetime as dt
import importlib.machinery
import json
import os
from pathlib import Path
root, work = Path(os.environ["ROOT"]), Path(os.environ["WORK"])
adapter = importlib.machinery.SourceFileLoader("adapter", str(root / "client/church-monitoring-streaming")).load_module()
now = dt.datetime.now(dt.timezone.utc)
stamp = now.isoformat().replace("+00:00", "Z")
group = {"name":"streaming","type":"group","provider":"yt-streamer"}
config = {"monitors":[{"name":"apache","type":"systemd"},group], "streaming_diagnostics":{"enabled":True}}
observation = {"severity":"ok","reason":"Healthy","observed_at":stamp,"age_seconds":0,"stale":False}
payload = {"schema_version":1,"generated_at":stamp,"components":{k:dict(observation) for k in adapter.FIELDS}}
payload["components"]["scheduling"].update(source="weekly",provider="api",calendar_required=False,
    decision_observed_at=None,weekly_observed_at=stamp,discovery_fresh=False)
payload["components"]["auth"]["mode"] = "not_applicable"
host = {"cpu":17,"memory":{"used":42},"services":[{"name":"apache","type":"systemd","status":"active"}],
        "slow_metrics":[{"id":"cert_expiry","value":"100d"}],"timestamp":"retained"}
for name, data in (("config",config),("streaming",payload),("host",host)):
    (work / (name + ".json")).write_text(json.dumps(data))
PY
sed -e "s|^CACHE=.*|CACHE=\"$WORK/host.json\"|" \
    -e "s|/usr/local/bin/church-monitoring-streaming|$WORK/adapter|g" \
    "$ROOT/client/status.cgi" > "$WORK/status.cgi"
cat > "$WORK/adapter" <<EOF
#!/usr/bin/env bash
exec python3 "$ROOT/client/church-monitoring-streaming" "\$@" --config "$WORK/config.json" --cache "$WORK/streaming.json"
EOF
chmod +x "$WORK/adapter"
QUERY_STRING='' bash "$WORK/status.cgi" | tail -n +3 > "$WORK/result.json"
jq -e '.cpu == 17 and .memory.used == 42 and .timestamp == "retained" and
    .services[0].name == "apache" and .services[1].severity == "ok" and
    (.services[1].children | length) == 4 and .slow_metrics[0].id == "cert_expiry"' "$WORK/result.json" >/dev/null
awk '/^monitor_digest_services\(\) \{/,/^}/' "$ROOT/server/church-status-report.sh" > "$WORK/functions.sh"
source "$WORK/functions.sh"
[[ -z "$(monitor_digest_services < "$WORK/result.json")" ]]
# Re-reading must expire source observations, not renew them from host cache time.
jq '.generated_at = "2000-01-01T00:00:00Z"' "$WORK/streaming.json" > "$WORK/new.json"
mv "$WORK/new.json" "$WORK/streaming.json"
QUERY_STRING='' bash "$WORK/status.cgi" | tail -n +3 > "$WORK/result.json"
jq -e '.services[1].severity == "unknown" and all(.services[1].children[]; .severity == "unknown")' "$WORK/result.json" >/dev/null
[[ -z "$(monitor_digest_services < "$WORK/result.json")" ]]
rm "$WORK/streaming.json"
QUERY_STRING='' bash "$WORK/status.cgi" | tail -n +3 | jq -e '
    .services[1].severity == "unknown" and (.services[1].children | length) == 4' >/dev/null
CONFIG="$WORK/config.json"
SERVICE_CLEAN=streaming-playback
awk '/^MATCH=\$\(jq/,/    "\$CONFIG" 2>\/dev\/null\)/' "$ROOT/client/restart-service.cgi" > "$WORK/authorization.sh"
source "$WORK/authorization.sh"
[[ -z "$MATCH" ]]
awk '/^install_packages\(\) \{/,/^}/' "$ROOT/client/install.sh" > "$WORK/packages.sh"
source "$WORK/packages.sh"
dpkg() { return 1; }
apt-get() { printf '%s\n' "$*" >> "$WORK/package-calls"; }
install_packages python3 >/dev/null
[[ "$(tail -n 1 "$WORK/package-calls")" == 'install -y python3' ]]
grep -q '^    install_packages python3$' "$ROOT/client/install.sh"
echo 'OK streaming status merge, freshness, digest exclusion, restart authorization and update runtime dependency'
