#!/usr/bin/env bash
# change-password.cgi — Self-service password change. Any logged-in user
# (any role) may change their OWN password, provided they know the current
# one. POST body: {"current_password":"...","new_password":"..."}
#
# For an admin resetting ANOTHER user's password without knowing the old
# one, see users.cgi's set-password action instead.

source /usr/local/lib/church-monitoring/auth-lib.sh

require_session

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

if [ "${REQUEST_METHOD:-}" != "POST" ]; then
    json_error "must be POST"
fi
if ! [[ "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]] || [ "${CONTENT_LENGTH:-0}" -le 0 ]; then
    json_error "empty or invalid request body"
fi

BODY=$(head -c "$CONTENT_LENGTH")
CURRENT=$(echo "$BODY" | jq -r '.current_password // empty' 2>/dev/null)
NEW=$(echo "$BODY" | jq -r '.new_password // empty' 2>/dev/null)

[ -z "$CURRENT" ] && json_error "missing current_password"
[ -z "$NEW" ] && json_error "missing new_password"
if [ "${#NEW}" -lt 8 ]; then
    json_error "new password must be at least 8 characters"
fi

USER_JSON=$(jq -c --arg u "$AUTH_USERNAME" '.users[] | select(.username == $u)' "$USERS_FILE" 2>/dev/null)
if [ -z "$USER_JSON" ]; then
    json_error "user account no longer exists"
fi

STORED_HASH=$(echo "$USER_JSON" | jq -r '.password_hash // empty')
if [ -z "$STORED_HASH" ] || ! printf '%s' "$CURRENT" | verify_password "$STORED_HASH"; then
    json_error "current password is incorrect"
fi

NEW_HASH=$(printf '%s' "$NEW" | hash_password)
set_password_hash "$AUTH_USERNAME" "$NEW_HASH"

echo "Content-Type: application/json"
echo ""
echo '{"result":"password changed"}'
