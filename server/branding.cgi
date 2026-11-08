#!/usr/bin/env bash
# branding.cgi — Returns the dashboard's display branding (title, icon,
# organization) from the "branding" section of server-config.json, falling
# back to generic defaults. Public on purpose: the login page needs it before
# a session exists, and it contains nothing but display text.

CONFIG="/etc/church-monitoring/server-config.json"

echo "Content-Type: application/json"
echo "Cache-Control: no-cache"
echo ""

jq -c '
  def pick($key; $default):
    (.branding[$key] // $default)
    | if type == "string" and length > 0 then .[0:80] else $default end;
  {title: pick("title"; "Church Monitoring"),
   icon: pick("icon"; "📡"),
   organization: pick("organization"; "")}
' "$CONFIG" 2>/dev/null || echo '{"title":"Church Monitoring","icon":"📡","organization":""}'
