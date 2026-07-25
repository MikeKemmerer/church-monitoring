#!/usr/bin/env bash
# logout.cgi — Clears the caller's session (server-side file + cookie).
# PUBLIC endpoint — safe to call whether or not a session currently exists.

source /usr/local/lib/church-monitoring/auth-lib.sh

destroy_current_session

echo "Content-Type: application/json"
echo "Set-Cookie: cmsession=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0"
echo ""
echo '{"result":"logged out"}'
