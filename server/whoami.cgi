#!/usr/bin/env bash
# whoami.cgi — Returns the current session's username/role, or a 401 if not
# logged in. Used by the dashboard on load to decide whether to redirect to
# login.html and which role-gated UI to show.

source /usr/local/lib/church-monitoring/auth-lib.sh

require_session

echo "Content-Type: application/json"
echo ""
jq -n --arg u "$AUTH_USERNAME" --arg r "$AUTH_ROLE" '{username:$u, role:$r}'
