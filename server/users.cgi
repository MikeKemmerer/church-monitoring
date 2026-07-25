#!/usr/bin/env bash
# users.cgi — Admin-only dashboard user management.
# ?action=list|add|remove|set-role|set-password|lock|unlock
#
# list: GET, no body.
# add: POST {"username":"...","password":"...","role":"user|contributor|admin"}
# remove: POST {"username":"..."}
# set-role: POST {"username":"...","role":"user|contributor|admin"}
# set-password: POST {"username":"...","new_password":"..."} — admin resetting
#   ANOTHER user's password without knowing the old one (self-service password
#   change lives in change-password.cgi instead).
# lock / unlock: POST {"username":"..."}
#
# Guard rail: refuses to remove/demote/lock the last remaining active (role
# admin, not locked) admin account, so the dashboard can never be locked out
# of its own admin-management UI entirely.

source /usr/local/lib/church-monitoring/auth-lib.sh

require_role admin

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

json_ok() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"result\":\"$1\"}"
    exit 0
}

ACTION=$(echo "${QUERY_STRING:-}" | tr '&' '\n' | grep '^action=' | cut -d= -f2- | head -1)
[ -z "$ACTION" ] && json_error "missing action parameter"

[ -f "$USERS_FILE" ] || json_error "no users configured"

read_body_json() {
    if ! [[ "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]] || [ "${CONTENT_LENGTH:-0}" -le 0 ]; then
        json_error "empty or invalid request body"
    fi
    head -c "$CONTENT_LENGTH"
}

user_exists() {
    local u="$1"
    local found
    found=$(jq -r --arg u "$u" '.users[] | select(.username == $u) | .username' "$USERS_FILE" 2>/dev/null)
    [ -n "$found" ]
}

# Counts admin accounts other than $1 that are active (role=admin, not locked).
count_other_active_admins() {
    local exclude="$1"
    jq -r --arg ex "$exclude" \
        '[.users[] | select(.username != $ex and .role == "admin" and (.locked // false) == false)] | length' \
        "$USERS_FILE"
}

validate_username() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]
}

validate_role() {
    case "$1" in
        user|contributor|admin) return 0 ;;
        *) return 1 ;;
    esac
}

case "$ACTION" in
    list)
        echo "Content-Type: application/json"
        echo ""
        jq '{users: [.users[] | {username, role, locked, failed_attempts, last_login, created}]}' "$USERS_FILE"
        ;;

    add)
        BODY=$(read_body_json)
        USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
        PASSWORD=$(echo "$BODY" | jq -r '.password // empty' 2>/dev/null)
        ROLE=$(echo "$BODY" | jq -r '.role // empty' 2>/dev/null)

        validate_username "$USERNAME" || json_error "username must be 3-32 characters (letters, digits, dash, underscore)"
        validate_role "$ROLE" || json_error "role must be user, contributor, or admin"
        [ "${#PASSWORD}" -lt 8 ] && json_error "password must be at least 8 characters"
        user_exists "$USERNAME" && json_error "user already exists"

        HASH=$(printf '%s' "$PASSWORD" | hash_password)
        TMP=$(mktemp)
        jq --arg u "$USERNAME" --arg h "$HASH" --arg r "$ROLE" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.users += [{"username":$u,"password_hash":$h,"role":$r,"locked":false,"failed_attempts":0,"lockout_until":0,"created":$t,"last_login":null}]' \
            "$USERS_FILE" > "$TMP" && _write_users_file "$TMP"
        json_ok "user added"
        ;;

    remove)
        BODY=$(read_body_json)
        USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
        [ -z "$USERNAME" ] && json_error "missing username"
        user_exists "$USERNAME" || json_error "user not found"
        [ "$USERNAME" = "$AUTH_USERNAME" ] && json_error "cannot remove your own account while logged in"

        TARGET_ROLE=$(jq -r --arg u "$USERNAME" '.users[] | select(.username == $u) | .role' "$USERS_FILE")
        if [ "$TARGET_ROLE" = "admin" ] && [ "$(count_other_active_admins "$USERNAME")" -eq 0 ]; then
            json_error "cannot remove the last remaining admin account"
        fi

        TMP=$(mktemp)
        jq --arg u "$USERNAME" '.users |= map(select(.username != $u))' "$USERS_FILE" > "$TMP" && _write_users_file "$TMP"
        json_ok "user removed"
        ;;

    set-role)
        BODY=$(read_body_json)
        USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
        ROLE=$(echo "$BODY" | jq -r '.role // empty' 2>/dev/null)
        [ -z "$USERNAME" ] && json_error "missing username"
        validate_role "$ROLE" || json_error "role must be user, contributor, or admin"
        user_exists "$USERNAME" || json_error "user not found"

        TARGET_ROLE=$(jq -r --arg u "$USERNAME" '.users[] | select(.username == $u) | .role' "$USERS_FILE")
        if [ "$TARGET_ROLE" = "admin" ] && [ "$ROLE" != "admin" ] && [ "$(count_other_active_admins "$USERNAME")" -eq 0 ]; then
            json_error "cannot demote the last remaining admin account"
        fi

        TMP=$(mktemp)
        jq --arg u "$USERNAME" --arg r "$ROLE" \
            '(.users[] | select(.username == $u)) |= (.role = $r)' \
            "$USERS_FILE" > "$TMP" && _write_users_file "$TMP"
        json_ok "role updated"
        ;;

    set-password)
        BODY=$(read_body_json)
        USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
        NEW=$(echo "$BODY" | jq -r '.new_password // empty' 2>/dev/null)
        [ -z "$USERNAME" ] && json_error "missing username"
        [ "${#NEW}" -lt 8 ] && json_error "new password must be at least 8 characters"
        user_exists "$USERNAME" || json_error "user not found"

        HASH=$(printf '%s' "$NEW" | hash_password)
        set_password_hash "$USERNAME" "$HASH"
        reset_failed_attempts "$USERNAME"
        json_ok "password reset"
        ;;

    lock)
        BODY=$(read_body_json)
        USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
        [ -z "$USERNAME" ] && json_error "missing username"
        user_exists "$USERNAME" || json_error "user not found"
        [ "$USERNAME" = "$AUTH_USERNAME" ] && json_error "cannot lock your own account while logged in"

        TARGET_ROLE=$(jq -r --arg u "$USERNAME" '.users[] | select(.username == $u) | .role' "$USERS_FILE")
        if [ "$TARGET_ROLE" = "admin" ] && [ "$(count_other_active_admins "$USERNAME")" -eq 0 ]; then
            json_error "cannot lock the last remaining admin account"
        fi

        TMP=$(mktemp)
        jq --arg u "$USERNAME" '(.users[] | select(.username == $u)) |= (.locked = true)' \
            "$USERS_FILE" > "$TMP" && _write_users_file "$TMP"
        json_ok "user locked"
        ;;

    unlock)
        BODY=$(read_body_json)
        USERNAME=$(echo "$BODY" | jq -r '.username // empty' 2>/dev/null)
        [ -z "$USERNAME" ] && json_error "missing username"
        user_exists "$USERNAME" || json_error "user not found"

        TMP=$(mktemp)
        jq --arg u "$USERNAME" \
            '(.users[] | select(.username == $u)) |= (.locked = false | .failed_attempts = 0 | .lockout_until = 0)' \
            "$USERS_FILE" > "$TMP" && _write_users_file "$TMP"
        json_ok "user unlocked"
        ;;

    *)
        json_error "unknown action"
        ;;
esac
