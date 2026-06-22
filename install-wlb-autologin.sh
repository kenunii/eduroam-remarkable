#!/usr/bin/env bash
set -euo pipefail

TARGET='root@10.11.99.1'
USERNAME=''
ACTION='install'
TMP_DIR=''
CONTROL_PATH=''

REMOTE_CONFIG_DIR='/home/root/.config/remarkable'
REMOTE_BIN_DIR='/home/root/.local/bin'
REMOTE_ENV='/home/root/.config/remarkable/wlb-captive.env'
REMOTE_SCRIPT='/home/root/.local/bin/wlb-captive-login'
REMOTE_SERVICE='/etc/systemd/system/wlb-captive-login.service'
REMOTE_TIMER='/etc/systemd/system/wlb-captive-login.timer'

usage() {
    cat <<'EOF'
Usage: ./install-wlb-autologin.sh [options]

Install, inspect, or remove automatic WLB Stuttgart captive-portal login on a
reMarkable 2. Credentials are stored on the tablet as root-only config.

Options:
  --target USER@HOST   SSH destination (default: root@10.11.99.1)
  --username NUMBER    WLB library card number
  --uninstall          Remove the auto-login timer, service, script, and credentials
  --status             Show the installed timer/service state and recent logs
  -h, --help           Show this help
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

askpass() {
    local prompt=$1
    local program=${WLB_ASKPASS:-${SSH_ASKPASS:-/usr/lib/git-core/git-gui--askpass}}

    [[ -x "$program" ]] || die "no terminal available and askpass helper not found: $program"
    DISPLAY=${DISPLAY:-:0} setsid -w "$program" "$prompt"
}

prompt_value() {
    local prompt=$1
    local value

    if [[ -t 0 ]]; then
        read -r -p "$prompt" value
    else
        value=$(askpass "$prompt")
    fi
    printf '%s' "$value"
}

prompt_secret() {
    local prompt=$1
    local value

    if [[ -t 0 ]]; then
        read -r -s -p "$prompt" value
        printf '\n' >&2
    else
        value=$(askpass "$prompt")
    fi
    printf '%s' "$value"
}

urlencode() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote_plus(sys.argv[1]))
PY
}

cleanup() {
    if [[ -n "${CONTROL_PATH:-}" && -S "${CONTROL_PATH:-}" ]]; then
        ssh -o "ControlPath=$CONTROL_PATH" -O exit "$TARGET" >/dev/null 2>&1 || true
    fi
    if [[ -n "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

open_ssh_master() {
    printf 'Opening SSH connection to %s...\n' "$TARGET"
    ssh \
        -o ControlMaster=yes \
        -o "ControlPath=$CONTROL_PATH" \
        -o ControlPersist=60 \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        -fnNT \
        "$TARGET"
}

remote() {
    ssh -o "ControlPath=$CONTROL_PATH" "$TARGET" "$@"
}

while (($#)); do
    case "$1" in
        --target)
            (($# >= 2)) || die '--target requires a value'
            TARGET=$2
            shift 2
            ;;
        --username)
            (($# >= 2)) || die '--username requires a value'
            USERNAME=$2
            shift 2
            ;;
        --uninstall)
            ACTION='uninstall'
            shift
            ;;
        --status)
            ACTION='status'
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

for command in mktemp python3 rm ssh; do
    require_command "$command"
done

TMP_DIR=$(mktemp -d)
CONTROL_PATH="$TMP_DIR/ssh-control"
trap cleanup EXIT

open_ssh_master

remote '
    set -eu
    test -x /usr/sbin/wpa_cli
    command -v wget >/dev/null
    command -v systemctl >/dev/null
' || die 'tablet does not expose the expected tools'

case "$ACTION" in
    status)
        remote "
            set -u
            printf '%s\n' '-- files --'
            for path in '$REMOTE_ENV' '$REMOTE_SCRIPT' '$REMOTE_SERVICE' '$REMOTE_TIMER'; do
                if [ -e \"\$path\" ]; then
                    stat -c '%a %U:%G %n' \"\$path\"
                else
                    printf 'missing %s\n' \"\$path\"
                fi
            done
            printf '%s\n' '-- timer --'
            systemctl status wlb-captive-login.timer --no-pager 2>/dev/null || true
            printf '%s\n' '-- service --'
            systemctl status wlb-captive-login.service --no-pager 2>/dev/null || true
            printf '%s\n' '-- recent logs --'
            journalctl -u wlb-captive-login.service --no-pager -n 80 2>/dev/null || true
        "
        exit 0
        ;;
    uninstall)
        remote "
            set -eu
            systemctl disable --now wlb-captive-login.timer >/dev/null 2>&1 || true
            rm -f '$REMOTE_TIMER' '$REMOTE_SERVICE' '$REMOTE_SCRIPT' '$REMOTE_ENV'
            systemctl daemon-reload
        "
        printf 'Removed WLB auto-login from %s.\n' "$TARGET"
        exit 0
        ;;
esac

if [[ -z "$USERNAME" ]]; then
    USERNAME=$(prompt_value 'WLB Ausweisnummer: ')
fi
[[ -n "$USERNAME" ]] || die 'WLB Ausweisnummer must not be empty'

PASSWORD=$(prompt_secret 'WLB Passwort: ')
[[ -n "$PASSWORD" ]] || die 'WLB password must not be empty'

ACCEPT_TERMS=$(prompt_value 'Accept WLB captive portal terms for automatic future logins? Type yes to continue: ')
[[ "$ACCEPT_TERMS" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] ||
    die 'WLB terms must be accepted before installing automatic captive portal login'

POST_DATA="tosaccept=tosaccept&username=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")&login=login"
unset PASSWORD

printf 'Installing auto-login files...\n'
remote "
    set -eu
    mkdir -p '$REMOTE_CONFIG_DIR' '$REMOTE_BIN_DIR'
    umask 077
    cat >'$REMOTE_ENV'
    chmod 600 '$REMOTE_ENV'
" <<EOF
WLB_POST_DATA='$POST_DATA'
EOF
unset POST_DATA

remote "cat >'$REMOTE_SCRIPT'" <<'EOF'
#!/bin/sh
set -eu

SSID='wifi@wlb'
CHECK_URL='http://connectivitycheck.gstatic.com/generate_204'
PORTAL_URL='https://gate.wlb-stuttgart.de/'
ENV_FILE='/home/root/.config/remarkable/wlb-captive.env'

log() {
    printf '%s\n' "$*"
    command -v logger >/dev/null 2>&1 && logger -t wlb-captive-login "$*" || true
}

ssid=$(/usr/sbin/wpa_cli -i wlan0 status 2>/dev/null | awk -F= '$1 == "ssid" { print $2; exit }')
if [ "$ssid" != "$SSID" ]; then
    log "not connected to $SSID; skipping"
    exit 0
fi

if ! ip -4 addr show dev wlan0 | grep -q 'inet '; then
    log "$SSID has no IPv4 address yet; skipping"
    exit 0
fi

check=$(wget -S -O - -T 10 "$CHECK_URL" 2>&1 || true)
if printf '%s\n' "$check" | grep -Eq 'HTTP/[0-9.]+ 204'; then
    log 'internet already available; skipping login'
    exit 0
fi

if ! printf '%s\n' "$check" | grep -Fq 'gate.wlb-stuttgart.de'; then
    log 'connectivity check did not show the WLB captive portal; skipping login'
    exit 0
fi

if [ ! -r "$ENV_FILE" ]; then
    log "missing credential file: $ENV_FILE"
    exit 1
fi

. "$ENV_FILE"
[ -n "${WLB_POST_DATA:-}" ] || {
    log 'WLB_POST_DATA is empty'
    exit 1
}

post_file=$(mktemp)
trap 'rm -f "$post_file" /tmp/wlb-captive-login.response' EXIT
umask 077
printf '%s\n' "$WLB_POST_DATA" >"$post_file"

wget -S -O - -T 20 --post-file "$post_file" "$PORTAL_URL" >/tmp/wlb-captive-login.response 2>&1 || true

after=$(wget -S -O - -T 10 "$CHECK_URL" 2>&1 || true)
if printf '%s\n' "$after" | grep -Eq 'HTTP/[0-9.]+ 204'; then
    log 'WLB captive portal login succeeded'
    exit 0
fi

log 'WLB captive portal login did not open internet access'
sed -n '1,80p' /tmp/wlb-captive-login.response || true
exit 1
EOF

remote "
    set -eu
    chmod 700 '$REMOTE_SCRIPT'
    cat >'$REMOTE_SERVICE' <<'EOF'
[Unit]
Description=WLB captive portal login
After=wpa_supplicant.service systemd-networkd.service
Wants=wpa_supplicant.service systemd-networkd.service

[Service]
Type=oneshot
ExecStart=$REMOTE_SCRIPT
EOF
    cat >'$REMOTE_TIMER' <<'EOF'
[Unit]
Description=Periodically check WLB captive portal login

[Timer]
OnBootSec=45s
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=false
Unit=wlb-captive-login.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 '$REMOTE_SERVICE' '$REMOTE_TIMER'
    systemctl daemon-reload
    systemctl enable --now wlb-captive-login.timer >/dev/null
"

printf 'Running one auto-login check now...\n'
remote "
    set -u
    systemctl start wlb-captive-login.service
    sleep 2
    systemctl status wlb-captive-login.service --no-pager || true
    printf '%s\n' '-- connectivity --'
    wget -S -O - -T 8 http://connectivitycheck.gstatic.com/generate_204 2>&1 | sed -n '1,30p' || true
    printf '%s\n' '-- timer --'
    systemctl list-timers --all --no-pager | grep -F wlb-captive-login || true
"

printf '\nWLB auto-login installed. Use --status or --uninstall to inspect or remove it.\n'
