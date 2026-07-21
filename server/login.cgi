#!/usr/bin/env bash
# login.cgi — Authenticates a dashboard user and issues a session cookie.
# PUBLIC endpoint (no session required to call this one). POST body:
#   {"username":"...","password":"..."}
#
# On success: sets the cmsession cookie, resets failed_attempts, records
# last_login. On failure: increments failed_attempts and applies the
# exponential lockout window once the threshold is crossed (see
# auth-lib.sh's compute_lockout_seconds). Always returns the same generic
# error message regardless of whether the username exists or the password
# was wrong, to avoid leaking which usernames are valid.

source /usr/local/lib/church-monitoring/auth-lib.sh

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
USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
PASSWORD=$(echo "$BODY" | jq -r '.password // empty' 2>/dev/null)

[ -z "$USERNAME" ] && json_error "missing username"
[ -z "$PASSWORD" ] && json_error "missing password"

cleanup_expired_sessions

if [ ! -f "$USERS_FILE" ]; then
    json_error "no users configured"
fi

USER_JSON=$(jq -c --arg u "$USERNAME" '.users[] | select(.username == $u)' "$USERS_FILE" 2>/dev/null)
if [ -z "$USER_JSON" ]; then
    json_error "invalid username or password"
fi

LOCKED=$(echo "$USER_JSON" | jq -r '.locked // false')
LOCKOUT_UNTIL=$(echo "$USER_JSON" | jq -r '.lockout_until // 0')
NOW=$(date +%s)

if [ "$LOCKED" = "true" ]; then
    json_error "account is locked; contact an administrator"
fi
if [[ "$LOCKOUT_UNTIL" =~ ^[0-9]+$ ]] && [ "$NOW" -lt "$LOCKOUT_UNTIL" ]; then
    WAIT=$((LOCKOUT_UNTIL - NOW))
    json_error "too many failed attempts; try again in ${WAIT}s"
fi

STORED_HASH=$(echo "$USER_JSON" | jq -r '.password_hash // empty')
if [ -n "$STORED_HASH" ] && printf '%s' "$PASSWORD" | verify_password "$STORED_HASH"; then
    reset_failed_attempts "$USERNAME"
    set_last_login "$USERNAME"
    ROLE=$(echo "$USER_JSON" | jq -r '.role')
    create_session "$USERNAME" "$ROLE"
    echo "Content-Type: application/json"
    echo "$AUTH_SET_COOKIE"
    echo ""
    jq -n --arg u "$USERNAME" --arg r "$ROLE" '{result:"ok", username:$u, role:$r}'
else
    record_failed_attempt "$USERNAME"
    json_error "invalid username or password"
fi
