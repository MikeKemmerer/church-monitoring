# auth-lib.sh — Shared session/RBAC helpers for the dashboard's server CGIs.
#
# Deployed to /usr/local/lib/church-monitoring/auth-lib.sh (NOT under CGI_DIR —
# ScriptAlias would try to execute it directly as a script if requested by URL;
# keeping it outside the web-exposed path is defense in depth). Every protected
# CGI sources it via the absolute path near the top of the script.
#
# Roles (ascending): user < contributor < admin. Only require_role()/
# require_session() ever write to stdout (a 401/403 JSON error + exit), so
# sourcing this file is otherwise silent.
#
# Password hashes are SHA-512 crypt (`openssl passwd -6`), generated/verified
# with the password piped via stdin — never via argv, which would leak the
# plaintext to any local user running `ps`.

USERS_FILE="/etc/church-monitoring/users.json"
SESSIONS_DIR="/etc/church-monitoring/sessions"
SESSION_LIFETIME_SECONDS=43200   # 12 hours, fixed (no sliding renewal)

AUTH_USERNAME=""
AUTH_ROLE=""
AUTH_SET_COOKIE=""

_auth_json_error() {
    local status="$1" msg="$2"
    echo "Status: $status"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$msg\"}"
    exit 0
}

_role_rank() {
    case "$1" in
        user) echo 1 ;;
        contributor) echo 2 ;;
        admin) echo 3 ;;
        *) echo 0 ;;
    esac
}

get_cookie() {
    local name="$1"
    echo "${HTTP_COOKIE:-}" | tr ';' '\n' | sed 's/^ *//' | grep "^${name}=" | cut -d= -f2- | head -1
}

# Reads the plaintext password from stdin, prints the SHA-512 crypt hash.
hash_password() {
    local salt
    salt=$(openssl rand -hex 8)
    openssl passwd -6 -salt "$salt" -stdin
}

# $1 = stored hash. Reads the candidate plaintext password from stdin.
# Prints nothing; returns 0 on match, 1 otherwise.
verify_password() {
    local stored="$1"
    local salt candidate
    salt=$(echo "$stored" | cut -d'$' -f3)
    [ -z "$salt" ] && return 1
    candidate=$(openssl passwd -6 -salt "$salt" -stdin)
    [ "$candidate" = "$stored" ]
}

# $1 = failed_attempts count. Prints the lockout duration in seconds (0 if
# below the threshold). 5th failure -> 30s, doubling each additional failure,
# capped at 1800s (30 minutes).
compute_lockout_seconds() {
    local attempts="${1:-0}"
    if [ "$attempts" -lt 5 ]; then
        echo 0
        return
    fi
    local exp=$((attempts - 5))
    if [ "$exp" -gt 6 ]; then exp=6; fi   # cap the shift before it overflows/exceeds max
    local secs=$((30 * (1 << exp)))
    if [ "$secs" -gt 1800 ]; then secs=1800; fi
    echo "$secs"
}

# Removes any session file whose expiry has passed. Cheap enough to call from
# login.cgi on every attempt; avoids needing a dedicated cron/systemd timer.
cleanup_expired_sessions() {
    [ -d "$SESSIONS_DIR" ] || return 0
    local now f exp
    now=$(date +%s)
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        exp=$(jq -r '.expires // 0' "$f" 2>/dev/null || echo 0)
        if ! [[ "$exp" =~ ^[0-9]+$ ]] || [ "$now" -ge "$exp" ]; then
            rm -f "$f"
        fi
    done
}

# $1 = username, $2 = role. Creates a session file and sets $AUTH_SET_COOKIE
# to the full Set-Cookie header line (caller must echo it before the blank
# line that ends the CGI headers).
create_session() {
    local username="$1" role="$2"
    local token token_hash expires
    token=$(openssl rand -hex 32)
    token_hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
    expires=$(( $(date +%s) + SESSION_LIFETIME_SECONDS ))
    mkdir -p "$SESSIONS_DIR"
    jq -n --arg u "$username" --arg r "$role" --argjson e "$expires" \
        '{username:$u, role:$r, expires:$e}' > "$SESSIONS_DIR/${token_hash}.json"
    chmod 600 "$SESSIONS_DIR/${token_hash}.json"
    AUTH_SET_COOKIE="Set-Cookie: cmsession=${token}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${SESSION_LIFETIME_SECONDS}"
}

# Deletes the session file for the current request's cookie (if any). Used by
# logout.cgi.
destroy_current_session() {
    local token token_hash
    token=$(get_cookie "cmsession")
    [ -z "$token" ] && return 0
    token_hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
    rm -f "$SESSIONS_DIR/${token_hash}.json"
}

# Validates the session cookie. On success sets $AUTH_USERNAME/$AUTH_ROLE. On
# failure, emits a 401 JSON error and exits the calling CGI (this is sourced,
# so `exit` here ends the whole script, matching the json_error() convention
# already used throughout the codebase).
require_session() {
    local token
    token=$(get_cookie "cmsession")
    if [ -z "$token" ]; then
        _auth_json_error "401 Unauthorized" "not logged in"
    fi

    local token_hash session_file
    token_hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
    session_file="$SESSIONS_DIR/${token_hash}.json"
    if [ ! -f "$session_file" ]; then
        _auth_json_error "401 Unauthorized" "session expired or invalid"
    fi

    local expires now
    expires=$(jq -r '.expires // 0' "$session_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    if ! [[ "$expires" =~ ^[0-9]+$ ]] || [ "$now" -ge "$expires" ]; then
        rm -f "$session_file"
        _auth_json_error "401 Unauthorized" "session expired"
    fi

    AUTH_USERNAME=$(jq -r '.username // empty' "$session_file")
    AUTH_ROLE=$(jq -r '.role // empty' "$session_file")
    if [ -z "$AUTH_USERNAME" ] || [ -z "$AUTH_ROLE" ]; then
        _auth_json_error "401 Unauthorized" "invalid session"
    fi
}

# $1 = minimum role required (user|contributor|admin). Validates the session
# and the role floor; emits 403 JSON and exits if the user's role is too low.
require_role() {
    local min_role="$1"
    require_session
    local have want
    have=$(_role_rank "$AUTH_ROLE")
    want=$(_role_rank "$min_role")
    if [ "$have" -lt "$want" ]; then
        _auth_json_error "403 Forbidden" "insufficient permissions"
    fi
}

# --- users.json mutation helpers ---

# Overwrites USERS_FILE's contents from a temp file, then removes the temp
# file. Deliberately uses `cp` (writes into the EXISTING inode, requiring
# only write permission on the file itself -- already granted via its
# root:www-data 660 ownership) rather than `mv`/rename, which requires
# write+execute permission on the *containing directory*
# (/etc/church-monitoring). That directory is deliberately NOT group-
# writable by www-data since it also holds the CA private key and other
# sensitive material -- `mv` across the /tmp -> /etc mktemp boundary is a
# cross-device rename anyway, which falls back to copy+unlink and fails
# with "unable to remove target: Permission denied" for exactly this
# reason (confirmed live in church-monitoring-error.log).
_write_users_file() {
    local tmp="$1"
    cp "$tmp" "$USERS_FILE"
    rm -f "$tmp"
}

reset_failed_attempts() {
    local username="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg u "$username" \
        '(.users[] | select(.username == $u)) |= (.failed_attempts = 0 | .lockout_until = 0)' \
        "$USERS_FILE" > "$tmp" && _write_users_file "$tmp"
}

record_failed_attempt() {
    local username="$1"
    local attempts lockout until tmp
    attempts=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .failed_attempts // 0' "$USERS_FILE")
    attempts=$((attempts + 1))
    lockout=$(compute_lockout_seconds "$attempts")
    until=0
    if [ "$lockout" -gt 0 ]; then
        until=$(( $(date +%s) + lockout ))
    fi
    tmp=$(mktemp)
    jq --arg u "$username" --argjson fa "$attempts" --argjson lu "$until" \
        '(.users[] | select(.username == $u)) |= (.failed_attempts = $fa | .lockout_until = $lu)' \
        "$USERS_FILE" > "$tmp" && _write_users_file "$tmp"
}

set_last_login() {
    local username="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg u "$username" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '(.users[] | select(.username == $u)) |= (.last_login = $t)' \
        "$USERS_FILE" > "$tmp" && _write_users_file "$tmp"
}

set_password_hash() {
    local username="$1" new_hash="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg u "$username" --arg h "$new_hash" \
        '(.users[] | select(.username == $u)) |= (.password_hash = $h)' \
        "$USERS_FILE" > "$tmp" && _write_users_file "$tmp"
}
