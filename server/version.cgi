#!/usr/bin/env bash
# version.cgi — Returns the installed release of the roles on this host
# (from /etc/church-monitoring/installed-version.json) for the dashboard footer.

source /usr/local/lib/church-monitoring/auth-lib.sh

require_session

echo "Content-Type: application/json"
echo ""
jq -c '{server: (.roles.server // null), client: (.roles.client // null)}' \
    /etc/church-monitoring/installed-version.json 2>/dev/null || echo '{"server":null,"client":null}'
