#!/usr/bin/env bash
set -euo pipefail

TARGET='root@10.11.99.1'
SSID='wifi@wlb'
REMOTE_CONFIG='/home/root/.config/remarkable/wifi_networks.conf'
PORTAL_URL='https://gate.wlb-stuttgart.de/'
CHECK_URL='http://connectivitycheck.gstatic.com/generate_204'
SKIP_LOGIN=0
USERNAME=''
TMP_DIR=''
CONTROL_PATH=''

usage() {
    cat <<'EOF'
Usage: ./setup-wlb.sh [options]

Configure and log in to the WLB Stuttgart captive portal on a reMarkable 2.

Options:
  --target USER@HOST   SSH destination (default: root@10.11.99.1)
  --username NUMBER    WLB library card number
  --skip-login         Only configure/select wifi@wlb, do not submit portal login
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

cleanup() {
    if [[ -n "${CONTROL_PATH:-}" && -S "${CONTROL_PATH:-}" ]]; then
        ssh -o "ControlPath=$CONTROL_PATH" -O exit "$TARGET" >/dev/null 2>&1 || true
    fi
    if [[ -n "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

wpa_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

urlencode() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote_plus(sys.argv[1]))
PY
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

wait_for_wlb() {
    local status=''
    local i

    printf 'Waiting for Wi-Fi association'
    for ((i = 0; i < 15; i++)); do
        status=$(remote '/usr/sbin/wpa_cli -i wlan0 status')
        if grep -Fq "ssid=$SSID" <<<"$status" &&
            grep -Fq 'wpa_state=COMPLETED' <<<"$status"; then
            printf '\n'
            break
        fi
        printf '.'
        sleep 2
    done

    grep -Fq "ssid=$SSID" <<<"$status" &&
        grep -Fq 'wpa_state=COMPLETED' <<<"$status" ||
        die "could not associate with $SSID"

    printf 'Waiting for DHCP'
    for ((i = 0; i < 12; i++)); do
        if remote "ip -4 addr show dev wlan0 | grep -q 'inet '"; then
            printf '\n'
            break
        fi
        printf '.'
        sleep 2
    done

    remote "ip -4 addr show dev wlan0 | grep -q 'inet '" ||
        die "$SSID associated, but DHCP did not provide an IPv4 address"
}

portal_state() {
    remote "
        set -u
        wget -S -O - -T 8 '$CHECK_URL' 2>&1 | sed -n '1,40p'
    "
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
        --skip-login)
            SKIP_LOGIN=1
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

for command in awk grep mktemp python3 rm ssh; do
    require_command "$command"
done

if ((SKIP_LOGIN == 0)); then
    if [[ -z "$USERNAME" ]]; then
        USERNAME=$(prompt_value 'WLB Ausweisnummer: ')
    fi
    [[ -n "$USERNAME" ]] || die 'WLB Ausweisnummer must not be empty'

    PASSWORD=$(prompt_secret 'WLB Passwort: ')
    [[ -n "$PASSWORD" ]] || die 'WLB password must not be empty'

    ACCEPT_TERMS=$(prompt_value 'Accept WLB captive portal terms? Type yes to continue: ')
    [[ "$ACCEPT_TERMS" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] ||
        die 'WLB terms must be accepted before submitting the captive portal login'
fi

TMP_DIR=$(mktemp -d)
CONTROL_PATH="$TMP_DIR/ssh-control"
trap cleanup EXIT

open_ssh_master

remote "
    set -eu
    test -x /usr/sbin/wpa_cli
    test -f '$REMOTE_CONFIG'
    command -v wget >/dev/null
    systemctl is-active --quiet wpa_supplicant.service
" || die 'tablet does not expose the expected stock Wi-Fi setup'

printf 'Configuring %s...\n' "$SSID"
BACKUP_PATH=$(
    remote "
        set -eu
        stamp=\$(date +%Y%m%d-%H%M%S)
        backup='$REMOTE_CONFIG.backup-wifi-wlb-'\$stamp
        cp -p '$REMOTE_CONFIG' \"\$backup\"
        printf '%s\n' \"\$backup\"
    "
)
printf 'Backup: %s\n' "$BACKUP_PATH"

NETWORK_ID=$(
    remote "/usr/sbin/wpa_cli -i wlan0 list_networks |
        awk -F '\t' '\$2 == \"$SSID\" { print \$1; exit }'"
)
if [[ -z "$NETWORK_ID" ]]; then
    NETWORK_ID=$(remote '/usr/sbin/wpa_cli -i wlan0 add_network')
fi
[[ "$NETWORK_ID" =~ ^[[:digit:]]+$ ]] ||
    die "could not determine $SSID network id: $NETWORK_ID"

{
    printf 'set_network %s ssid %s\n' "$NETWORK_ID" "$(wpa_quote "$SSID")"
    printf 'set_network %s key_mgmt NONE\n' "$NETWORK_ID"
    printf 'set_network %s auth_alg OPEN\n' "$NETWORK_ID"
    printf 'set_network %s priority 3\n' "$NETWORK_ID"
    printf 'enable_network all\n'
    printf 'enable_network %s\n' "$NETWORK_ID"
    printf 'save_config\n'
    printf 'select_network %s\n' "$NETWORK_ID"
    printf 'quit\n'
} | remote '
    set -eu
    output=$(mktemp)
    trap "rm -f \"$output\"" EXIT
    /usr/sbin/wpa_cli -i wlan0 >"$output"
    if grep -Eq "(^|[[:space:]])FAIL([[:space:]]|$)|UNKNOWN COMMAND" "$output"; then
        cat "$output" >&2
        exit 1
    fi
'

wait_for_wlb

printf '\nConnection status:\n'
remote "/usr/sbin/wpa_cli -i wlan0 status |
    grep -E '^(ssid|wpa_state|ip_address|bssid|freq|key_mgmt)='"

printf '\nCaptive portal check before login:\n'
before=$(portal_state)
printf '%s\n' "$before"

if ((SKIP_LOGIN)); then
    printf '\nConfigured %s and skipped portal login.\n' "$SSID"
    exit 0
fi

post_data="tosaccept=tosaccept&username=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")&login=login"
unset PASSWORD

printf '\nSubmitting captive portal login...\n'
printf '%s\n' "$post_data" | remote "
    set -eu
    post_file=\$(mktemp)
    trap 'rm -f \"\$post_file\"' EXIT
    umask 077
    cat >\"\$post_file\"
    wget -S -O - -T 15 --post-file \"\$post_file\" '$PORTAL_URL' 2>&1 | sed -n '1,80p'
"
unset post_data

printf '\nCaptive portal check after login:\n'
after=$(portal_state)
printf '%s\n' "$after"

if grep -Eq 'HTTP/[0-9.]+ 204' <<<"$after"; then
    printf '\nWLB captive portal login succeeded.\n'
elif grep -Fq 'Location: https://gate.wlb-stuttgart.de/' <<<"$after" ||
    grep -Fq 'WLB Login' <<<"$after"; then
    die 'portal still redirects to the WLB login page; credentials or portal state need checking'
else
    printf '\nPortal no longer returned the known login redirect. Check connectivity manually if needed.\n'
fi
