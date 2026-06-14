#!/usr/bin/env bash
# backup.sh — Creates a disaster-recovery archive of this client's app configs.
# Installed as /usr/local/bin/church-monitoring-backup and run as root.
#
# Reads the `apps` array from client-config.json (the source of truth for what is
# installed on this host), copies the config_paths that exist into a staging tree,
# writes a manifest.json describing how to rebuild each app, tars everything into
# the backup dir, prunes to the configured retention count, and prints a JSON
# summary to stdout.
#
# Exit code is always 0 for the CGI caller; failures are reported in the JSON.

set -euo pipefail

CONFIG="/etc/church-monitoring/client-config.json"

emit_error() {
    # Print a JSON error object and exit cleanly so the CGI caller gets valid JSON.
    local msg="$1"
    jq -n --arg error "$msg" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{ok: false, error: $error, timestamp: $ts}'
    exit 0
}

command -v jq >/dev/null 2>&1 || emit_error "jq not installed"
command -v tar >/dev/null 2>&1 || emit_error "tar not installed"
[ -f "$CONFIG" ] || emit_error "client-config.json not found at $CONFIG"

HOSTNAME_VAL=$(jq -r '.hostname // empty' "$CONFIG" 2>/dev/null || echo "")
[ -z "$HOSTNAME_VAL" ] && HOSTNAME_VAL=$(hostname)

BACKUP_DIR=$(jq -r '.backup.dir // "/var/backups/church-monitoring"' "$CONFIG" 2>/dev/null || echo "/var/backups/church-monitoring")
KEEP=$(jq -r '.backup.keep // 5' "$CONFIG" 2>/dev/null || echo 5)
[[ "$KEEP" =~ ^[0-9]+$ ]] || KEEP=5

newest_archive() {
    ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1 || true
}

# Helper modes used by the download CGI (run as root via sudo).
case "${1:-}" in
    --latest-path)
        # Print the path of the newest archive (or nothing) and exit.
        newest_archive
        exit 0
        ;;
    --emit-latest)
        # Stream the newest archive to stdout so the CGI can serve it.
        latest=$(newest_archive)
        [ -n "$latest" ] && [ -f "$latest" ] || exit 1
        cat "$latest"
        exit 0
        ;;
esac


# Paths excluded from backup even if listed (regeneratable, potentially large).
# Matched as a suffix of any config_path.
EXCLUDE_SUFFIXES=("/captures" "/thumbnails")

is_excluded() {
    local path="$1"
    local suffix
    for suffix in "${EXCLUDE_SUFFIXES[@]}"; do
        case "$path" in
            *"$suffix") return 0 ;;
        esac
    done
    return 1
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2>/dev/null || true

STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

PAYLOAD="$STAGING/payload"
mkdir -p "$PAYLOAD"

# Track results as JSON arrays for the manifest and summary.
APPS_INCLUDED="[]"
PATHS_SKIPPED="[]"

# Iterate apps from config, sorted by their install order.
while IFS= read -r app; do
    APP_NAME=$(echo "$app" | jq -r '.name')
    [ -z "$APP_NAME" ] && continue

    INCLUDED_PATHS="[]"

    while IFS= read -r cfg_path; do
        [ -z "$cfg_path" ] && continue

        if is_excluded "$cfg_path"; then
            PATHS_SKIPPED=$(echo "$PATHS_SKIPPED" | jq \
                --arg p "$cfg_path" --arg r "excluded" \
                '. + [{path: $p, reason: $r}]')
            continue
        fi

        if [ ! -e "$cfg_path" ]; then
            PATHS_SKIPPED=$(echo "$PATHS_SKIPPED" | jq \
                --arg p "$cfg_path" --arg r "missing" \
                '. + [{path: $p, reason: $r}]')
            continue
        fi

        # Mirror the absolute path under the staging payload so restore can place
        # it back exactly where it came from.
        DEST="$PAYLOAD${cfg_path}"
        mkdir -p "$(dirname "$DEST")"
        cp -a "$cfg_path" "$DEST"
        INCLUDED_PATHS=$(echo "$INCLUDED_PATHS" | jq --arg p "$cfg_path" '. + [$p]')
    done < <(echo "$app" | jq -r '.config_paths[]? // empty')

    # Record the app in the manifest with its included paths resolved.
    APP_ENTRY=$(echo "$app" | jq --argjson included "$INCLUDED_PATHS" \
        '{name, repo, branch, installer_cmd, apt, pip, config_paths, service_names, order,
          included_paths: $included}')
    APPS_INCLUDED=$(echo "$APPS_INCLUDED" | jq --argjson e "$APP_ENTRY" '. + [$e]')
done < <(jq -c '(.apps // []) | sort_by(.order) | .[]' "$CONFIG" 2>/dev/null)

# Write the manifest that restore.sh consumes.
MANIFEST="$STAGING/manifest.json"
jq -n \
    --arg hostname "$HOSTNAME_VAL" \
    --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg stamp "$STAMP" \
    --argjson apps "$APPS_INCLUDED" \
    '{
        manifest_version: 1,
        hostname: $hostname,
        created_utc: $created,
        stamp: $stamp,
        apps: $apps
    }' > "$MANIFEST"

ARCHIVE="$BACKUP_DIR/backup-${HOSTNAME_VAL}-${STAMP}.tar.gz"

# Build the archive: manifest.json at the root, payload/ holding the mirrored files.
if ! tar -czf "$ARCHIVE" -C "$STAGING" manifest.json payload 2>/dev/null; then
    emit_error "failed to create archive"
fi
chmod 600 "$ARCHIVE" 2>/dev/null || true

# Prune older archives, keeping the newest $KEEP.
mapfile -t ALL_ARCHIVES < <(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null || true)
if [ "${#ALL_ARCHIVES[@]}" -gt "$KEEP" ]; then
    for old in "${ALL_ARCHIVES[@]:$KEEP}"; do
        rm -f "$old"
    done
fi

SIZE_BYTES=$(stat -c %s "$ARCHIVE" 2>/dev/null || echo 0)
APP_COUNT=$(echo "$APPS_INCLUDED" | jq 'length')

jq -n \
    --arg archive "$ARCHIVE" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson size_bytes "$SIZE_BYTES" \
    --argjson app_count "$APP_COUNT" \
    --argjson apps_included "$APPS_INCLUDED" \
    --argjson paths_skipped "$PATHS_SKIPPED" \
    '{
        ok: true,
        archive: $archive,
        size_bytes: $size_bytes,
        app_count: $app_count,
        apps: [$apps_included[].name],
        paths_skipped: $paths_skipped,
        timestamp: $ts
    }'
