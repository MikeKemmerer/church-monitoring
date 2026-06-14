#!/usr/bin/env bash
# restore.sh — Disaster-recovery restore for a church-monitoring client.
#
# Rebuilds a client from a backup archive produced by church-monitoring-backup:
# clones each app's repo, runs its installer, reinstalls prerequisites, and
# restores the local configuration files — in the order recorded in the archive
# manifest. Designed to be run as root on a fresh Raspberry Pi.
#
# Usage:
#   sudo ./restore.sh <archive.tar.gz> [options]
#
# Options:
#   --list             Print the apps contained in the archive and exit.
#   --apps a,b,c       Restore only the named apps (default: all in the archive).
#   --configs-only     Skip cloning/installing/prereqs; only reapply config files.
#   -h, --help         Show this help.
#
# Notes:
#   * church-monitoring is always restored LAST and re-enrolls with the server
#     (install.sh --renew prompts for the server address and a fresh token).
#   * videokiosk2's local.conf is restored BEFORE its installer runs so the
#     installer can pre-seed from it.
#   * The script continues on per-app errors and prints a summary at the end.

set -uo pipefail

WORKDIR="/opt/church-monitoring-restore"
ARCHIVE=""
LIST_ONLY=0
CONFIGS_ONLY=0
SELECTED_APPS=""

usage() { sed -n '2,30p' "$0"; exit "${1:-0}"; }

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --configs-only) CONFIGS_ONLY=1; shift ;;
        --apps) SELECTED_APPS="${2:-}"; shift 2 ;;
        --apps=*) SELECTED_APPS="${1#*=}"; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *) ARCHIVE="$1"; shift ;;
    esac
done

if [[ -z "$ARCHIVE" ]]; then
    echo "Error: no archive specified." >&2
    usage 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
    echo "Error: archive not found: $ARCHIVE" >&2
    exit 1
fi
if [[ $LIST_ONLY -eq 0 && $EUID -ne 0 ]]; then
    echo "Error: restore must be run as root (use sudo)." >&2
    exit 1
fi
command -v jq  >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Error: tar is required." >&2; exit 1; }

# ── Extract the archive ──────────────────────────────────────────────
EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT
if ! tar -xzf "$ARCHIVE" -C "$EXTRACT" 2>/dev/null; then
    echo "Error: failed to extract archive." >&2
    exit 1
fi
MANIFEST="$EXTRACT/manifest.json"
PAYLOAD="$EXTRACT/payload"
if [[ ! -f "$MANIFEST" ]]; then
    echo "Error: archive has no manifest.json." >&2
    exit 1
fi

ARCHIVE_HOST=$(jq -r '.hostname // "unknown"' "$MANIFEST")

# ── --list: show contents and exit ───────────────────────────────────
if [[ $LIST_ONLY -eq 1 ]]; then
    echo "Backup of host: $ARCHIVE_HOST"
    echo "Created:        $(jq -r '.created_utc // "unknown"' "$MANIFEST")"
    echo "Apps (in restore order):"
    jq -r '.apps | sort_by(.order) | .[] |
        "  - \(.name) (order \(.order))\n" +
        (.included_paths // [] | map("      " + .) | join("\n"))' "$MANIFEST"
    exit 0
fi

# Build the set of app names to restore.
should_restore() {
    local name="$1"
    [[ -z "$SELECTED_APPS" ]] && return 0
    local a
    IFS=',' read -ra a <<< "$SELECTED_APPS"
    for x in "${a[@]}"; do
        [[ "$x" == "$name" ]] && return 0
    done
    return 1
}

# ── Helpers ──────────────────────────────────────────────────────────
declare -a RESULTS=()
record() { RESULTS+=("$1"); }

restore_configs() {
    # Copy each included path from the payload back to its absolute location.
    local app_json="$1" name count=0
    name=$(echo "$app_json" | jq -r '.name')
    while IFS= read -r abs; do
        [[ -z "$abs" ]] && continue
        local src="${PAYLOAD}${abs}"
        if [[ ! -e "$src" ]]; then
            echo "    ! missing in archive: $abs"
            continue
        fi
        mkdir -p "$(dirname "$abs")"
        if cp -a "$src" "$abs" 2>/dev/null; then
            echo "    restored $abs"
            count=$((count + 1))
        else
            echo "    ! failed to restore $abs"
        fi
    done < <(echo "$app_json" | jq -r '.included_paths[]? // empty')
    echo "    ($count path(s) restored for $name)"
}

apt_install() {
    local app_json="$1" pkgs
    mapfile -t pkgs < <(echo "$app_json" | jq -r '.apt[]? // empty')
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        echo "    apt: ${pkgs[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || \
            echo "    ! some apt packages failed (continuing)"
    fi
}

clone_repo() {
    # Clones (or updates) the app repo into WORKDIR; echoes the checkout path.
    local app_json="$1" name repo branch dest
    name=$(echo "$app_json" | jq -r '.name')
    repo=$(echo "$app_json" | jq -r '.repo // empty')
    branch=$(echo "$app_json" | jq -r '.branch // "master"')
    dest="$WORKDIR/$name"
    if [[ -z "$repo" ]]; then
        return 1
    fi
    if [[ -d "$dest/.git" ]]; then
        git -C "$dest" fetch --depth 1 origin "$branch" >/dev/null 2>&1 || true
        git -C "$dest" checkout "$branch" >/dev/null 2>&1 || true
        git -C "$dest" reset --hard "origin/$branch" >/dev/null 2>&1 || true
    else
        rm -rf "$dest"
        git clone --depth 1 --branch "$branch" "$repo" "$dest" >/dev/null 2>&1 || return 1
    fi
    echo "$dest"
}

run_installer() {
    local app_json="$1" dest="$2" cmd
    cmd=$(echo "$app_json" | jq -r '.installer_cmd // empty')
    [[ -z "$cmd" ]] && { echo "    (no installer_cmd)"; return 0; }
    echo "    installer: $cmd"
    ( cd "$dest" && bash -c "$cmd" )
}

enable_services() {
    local app_json="$1" svc
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        systemctl enable --now "$svc" >/dev/null 2>&1 \
            && echo "    enabled $svc" \
            || echo "    ! could not enable $svc"
    done < <(echo "$app_json" | jq -r '.service_names[]? // empty')
}

# ── --configs-only path ──────────────────────────────────────────────
if [[ $CONFIGS_ONLY -eq 1 ]]; then
    echo "Configs-only restore from backup of $ARCHIVE_HOST"
    while IFS= read -r app_json; do
        name=$(echo "$app_json" | jq -r '.name')
        should_restore "$name" || continue
        echo "==> $name"
        restore_configs "$app_json"
        record "$name: configs restored"
    done < <(jq -c '.apps | sort_by(.order) | .[]' "$MANIFEST")
    echo ""
    echo "Summary:"; printf '  %s\n' "${RESULTS[@]}"
    echo "Note: services were not restarted. Reload/restart them as needed."
    exit 0
fi

# ── Full restore ─────────────────────────────────────────────────────
echo "Full restore from backup of $ARCHIVE_HOST"
mkdir -p "$WORKDIR"

echo "==> Installing base prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
apt-get install -y git curl jq tar rsync || echo "  ! base prereqs partially failed (continuing)"

while IFS= read -r app_json; do
    name=$(echo "$app_json" | jq -r '.name')
    should_restore "$name" || continue

    echo ""
    echo "==> Restoring $name"

    if [[ "$name" == "church-monitoring" ]]; then
        # Agent is restored last and re-enrolls interactively.
        apt_install "$app_json"
        dest=$(clone_repo "$app_json") || { echo "  ! clone failed"; record "$name: CLONE FAILED"; continue; }
        echo "  Re-enrolling agent (you will be prompted for the server address and a token)."
        if run_installer "$app_json" "$dest"; then
            restore_configs "$app_json"
            echo "  Applying restored config (install.sh --update)."
            ( cd "$dest" && bash -c "sudo ./client/install.sh --update" ) || echo "  ! --update failed"
            enable_services "$app_json"
            record "$name: restored + re-enrolled"
        else
            echo "  ! installer failed"
            record "$name: INSTALLER FAILED"
        fi
        continue
    fi

    apt_install "$app_json"
    dest=$(clone_repo "$app_json") || { echo "  ! clone failed"; record "$name: CLONE FAILED"; continue; }

    if [[ "$name" == "videokiosk2" ]]; then
        # Restore local.conf first so the installer pre-seeds from it.
        echo "  Pre-seeding config before installer."
        restore_configs "$app_json"
        if run_installer "$app_json" "$dest"; then
            enable_services "$app_json"
            record "$name: restored"
        else
            record "$name: INSTALLER FAILED"
        fi
        continue
    fi

    if run_installer "$app_json" "$dest"; then
        restore_configs "$app_json"
        enable_services "$app_json"
        record "$name: restored"
    else
        echo "  ! installer failed"
        record "$name: INSTALLER FAILED"
    fi
done < <(jq -c '.apps | sort_by(.order) | .[]' "$MANIFEST")

echo ""
echo "===================== Restore summary ====================="
printf '  %s\n' "${RESULTS[@]}"
echo "==========================================================="
echo "Working checkouts left in $WORKDIR for inspection."
