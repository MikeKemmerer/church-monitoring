#!/usr/bin/env bash
# Configures complain-mode AppArmor hats for Church Monitoring Apache CGI paths.

set -euo pipefail

ROLE=""
MODE="complain"
CAMERA_WEB_ROOT="/var/www/html"
PROFILE_PATH="/etc/apparmor.d/usr.sbin.apache2"
PROFILE_MARKER="# Managed by church-monitoring/configure-apparmor.sh"

usage() {
    cat <<'EOF'
Usage: sudo ./configure-apparmor.sh --role server|client|cameras [options]

Configures AppArmor hats for Church Monitoring CGI endpoints or Camera Control
on Ubuntu.
It requires Apache's prefork MPM because libapache2-mod-apparmor is only tested
with that MPM. The default complain mode records required accesses without
blocking requests. Use enforce mode only after reviewing AppArmor logs.

Options:
    --mode complain|enforce     Set the selected hat mode (default: complain).
    --camera-web-root PATH      Camera Control web root (default: /var/www/html).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            ROLE="${2:-}"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --camera-web-root)
            CAMERA_WEB_ROOT="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Error: run this script as root." >&2
    exit 1
fi

if [[ "$ROLE" != "server" && "$ROLE" != "client" && "$ROLE" != "cameras" ]]; then
    echo "Error: --role must be server, client, or cameras." >&2
    exit 1
fi

if [[ "$MODE" != "complain" && "$MODE" != "enforce" ]]; then
    echo "Error: --mode must be complain or enforce." >&2
    exit 1
fi

if [[ ! "$CAMERA_WEB_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: --camera-web-root must be an absolute path with safe characters." >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "Skipping AppArmor: cannot identify the operating system."
    exit 0
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Skipping AppArmor: Church Monitoring Apache hats are only configured on Ubuntu."
    exit 0
fi

if ! apache2ctl -M 2>/dev/null | grep -q 'mpm_prefork_module'; then
    cat >&2 <<'EOF'
Skipping AppArmor: Apache is not using the prefork MPM.
libapache2-mod-apparmor is only tested with prefork; this script will not change
the host MPM. Switch Apache to prefork deliberately, then rerun this command.
EOF
    exit 0
fi

apt-get install -y apparmor apparmor-utils libapache2-mod-apparmor
systemctl enable --now apparmor.service >/dev/null 2>&1 || true
if ! aa-status --enabled >/dev/null 2>&1; then
    echo "Skipping AppArmor: the kernel has AppArmor disabled." >&2
    exit 0
fi

if [[ -e "$PROFILE_PATH" ]] && ! grep -Fqx "$PROFILE_MARKER" "$PROFILE_PATH"; then
    cat >&2 <<EOF
Refusing to replace the existing Apache AppArmor profile at $PROFILE_PATH.
Add Church Monitoring hats to that host-managed profile, or remove it only if it
is no longer needed. No Apache configuration was changed.
EOF
    exit 1
fi

cat > "$PROFILE_PATH" <<EOF
$PROFILE_MARKER
# The Apache parent stays in complain mode. Only the monitoring CGI hats use
# the requested mode, so enforcing them cannot prevent Apache from starting.
#include <tunables/global>

profile /usr/sbin/apache2 flags=(complain) {
  #include <abstractions/base>
  #include <abstractions/apache2-common>

  # Server dashboard CGI requests.
  ^church-monitoring-server flags=($MODE) {
    #include <abstractions/base>
    /bin/** rix,
    /usr/bin/** rix,
    /usr/lib/** mr,
    /etc/church-monitoring/ r,
    /etc/church-monitoring/** rw,
    /usr/lib/cgi-bin/church-monitoring-server/ r,
    /usr/lib/cgi-bin/church-monitoring-server/** rix,
    /usr/local/lib/church-monitoring/ r,
    /usr/local/lib/church-monitoring/** r,
    /var/cache/church-monitoring/ rw,
    /var/cache/church-monitoring/** rwk,
    /tmp/** rw,
    /run/** rw,
    network,
  }

  # Client agent CGI requests.
  ^church-monitoring-client flags=($MODE) {
    #include <abstractions/base>
    /bin/** rix,
    /usr/bin/** rix,
    /usr/lib/** mr,
    /etc/church-monitoring/ r,
    /etc/church-monitoring/** r,
    /usr/lib/cgi-bin/church-monitoring-client/ r,
    /usr/lib/cgi-bin/church-monitoring-client/** rix,
    /usr/local/bin/church-monitoring-* rix,
    /var/cache/church-monitoring/ r,
    /var/cache/church-monitoring/** rw,
    /tmp/** rw,
    /run/** rw,
    network,
  }

    # Camera Control PHP requests, image capture, and reverse-proxy traffic.
    ^church-camera-control flags=($MODE) {
        #include <abstractions/base>
        /bin/** rix,
        /usr/bin/ffmpeg rix,
        /usr/bin/** rix,
        /usr/lib/** mr,
        /usr/share/php/** r,
        /etc/php/** r,
        /dev/{null,random,urandom} rw,
        /proc/** r,
        /run/** rw,
        /tmp/** rw,
        $CAMERA_WEB_ROOT/ r,
        $CAMERA_WEB_ROOT/cameracontrol/ rw,
        $CAMERA_WEB_ROOT/cameracontrol/** rwk,
        $CAMERA_WEB_ROOT/multicamera/ rw,
        $CAMERA_WEB_ROOT/multicamera/** rwk,
        network,
    }
}
EOF

apparmor_parser -r "$PROFILE_PATH"
a2enmod apparmor >/dev/null

if [[ "$ROLE" == "cameras" ]]; then
    CONF_NAME="church-camera-control-apparmor"
    cat > "/etc/apache2/conf-available/${CONF_NAME}.conf" <<EOF
<Directory ${CAMERA_WEB_ROOT}/cameracontrol>
    AAHatName church-camera-control
</Directory>
<Directory ${CAMERA_WEB_ROOT}/multicamera>
    AAHatName church-camera-control
</Directory>
EOF
else
    CONF_NAME="church-monitoring-${ROLE}-apparmor"
    CGI_DIR="/usr/lib/cgi-bin/church-monitoring-${ROLE}"
    cat > "/etc/apache2/conf-available/${CONF_NAME}.conf" <<EOF
<Directory ${CGI_DIR}>
    AAHatName church-monitoring-${ROLE}
</Directory>
EOF
fi
a2enconf "$CONF_NAME" >/dev/null
systemctl reload apache2

echo "Configured $ROLE AppArmor hat in $MODE mode."
echo "Review journalctl -k | grep apparmor before using --mode enforce."