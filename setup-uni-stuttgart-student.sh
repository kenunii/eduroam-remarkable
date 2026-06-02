#!/usr/bin/env bash
set -euo pipefail

CAT_URL='https://cat.eduroam.org/user/API.php?action=downloadInstaller&lang=en&profile=5005&device=linux&generatedfor=user&openroaming=0'
REMOTE_CONFIG='/home/root/.config/remarkable/wifi_networks.conf'
REMOTE_CA='/home/root/.config/remarkable/eduroam-uni-stuttgart-ca.pem'
TARGET='root@10.11.99.1'
SKIP_CONNECT=0
USERNAME=''
TMP_DIR=''
CONTROL_PATH=''

usage() {
    cat <<'EOF'
Usage: ./setup-uni-stuttgart-student.sh [options]

Configure a reMarkable 2 for the University of Stuttgart student eduroam
profile, including CA and RADIUS server name validation.

Options:
  --target USER@HOST   SSH destination (default: root@10.11.99.1)
  --username IDENTITY  Full identity, for example st123456@stud.uni-stuttgart.de
  --skip-connect       Install the profile without selecting or testing it
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

check_cat_profile() {
    local profile=$1
    local ca_bundle=$2
    local cert_count

    grep -Fq 'Config.server_match = "eduroam.uni-stuttgart.de"' "$profile" ||
        die 'CAT profile changed: unexpected RADIUS server'
    grep -Fq 'Config.eap_outer = "PEAP"' "$profile" ||
        die 'CAT profile changed: expected PEAP'
    grep -Fq 'Config.eap_inner = "MSCHAPV2"' "$profile" ||
        die 'CAT profile changed: expected MSCHAPV2'
    grep -Fq "Config.servers = ['DNS:eduroam.uni-stuttgart.de']" "$profile" ||
        die 'CAT profile changed: unexpected server name match'
    grep -Fq 'Config.anonymous_identity = "eduroam@stud.uni-stuttgart.de"' "$profile" ||
        die 'CAT profile changed: unexpected outer identity'

    awk '
        /^Config\.CA = """/ {
            capture = 1
            sub(/^Config\.CA = """/, "")
            if (length) {
                print
            }
            next
        }
        capture {
            if (/^"""$/) {
                exit
            }
            print
        }
    ' "$profile" >"$ca_bundle"

    cert_count=$(grep -c '^-----BEGIN CERTIFICATE-----$' "$ca_bundle" || true)
    [[ "$cert_count" == 2 ]] ||
        die "CAT profile changed: expected 2 CA certificates, found $cert_count"
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

wait_for_eduroam() {
    local status=''
    local i

    printf 'Waiting for EAP authentication'
    for ((i = 0; i < 15; i++)); do
        status=$(remote '/usr/sbin/wpa_cli -i wlan0 status')
        if grep -Fq 'ssid=eduroam' <<<"$status" &&
            grep -Fq 'wpa_state=COMPLETED' <<<"$status" &&
            grep -Fq 'EAP state=SUCCESS' <<<"$status"; then
            printf '\n'
            break
        fi
        printf '.'
        sleep 2
    done

    grep -Fq 'ssid=eduroam' <<<"$status" &&
        grep -Fq 'wpa_state=COMPLETED' <<<"$status" &&
        grep -Fq 'EAP state=SUCCESS' <<<"$status" ||
        die 'eduroam EAP authentication did not complete'

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
        die 'eduroam authentication succeeded, but DHCP did not provide an IPv4 address'

    printf '\nConnection status:\n'
    remote "/usr/sbin/wpa_cli -i wlan0 status |
        grep -E '^(ssid|wpa_state|ip_address|EAP state|selectedMethod|eap_tls_version|EAP TLS cipher|EAP-PEAPv0 Phase2 method)='"

    printf '\nInternet connectivity:\n'
    remote 'ping -c 1 -W 3 1.1.1.1'
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
        --skip-connect)
            SKIP_CONNECT=1
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

for command in awk curl grep mktemp rm ssh; do
    require_command "$command"
done

if [[ -z "$USERNAME" ]]; then
    read -r -p 'Student identity (st123456@stud.uni-stuttgart.de): ' USERNAME
fi
[[ "$USERNAME" =~ ^st[[:digit:]]+@stud\.uni-stuttgart\.de$ ]] ||
    die 'identity must have the form st123456@stud.uni-stuttgart.de'

read -r -s -p 'SIAM password: ' PASSWORD
printf '\n'
[[ -n "$PASSWORD" ]] || die 'password must not be empty'

TMP_DIR=$(mktemp -d)
CONTROL_PATH="$TMP_DIR/ssh-control"
trap cleanup EXIT

printf 'Downloading current Uni Stuttgart CAT profile...\n'
curl -fsSL "$CAT_URL" >"$TMP_DIR/cat-installer.py"
check_cat_profile "$TMP_DIR/cat-installer.py" "$TMP_DIR/ca.pem"
printf 'CAT profile validated.\n'

open_ssh_master

remote "
    set -eu
    test -x /usr/sbin/wpa_cli
    test -f '$REMOTE_CONFIG'
    systemctl is-active --quiet wpa_supplicant.service
" || die 'tablet does not expose the expected stock wpa_supplicant setup'

printf 'Backing up Wi-Fi configuration and installing CA bundle...\n'
BACKUP_PATH=$(
    remote "
        set -eu
        umask 077
        stamp=\$(date +%Y%m%d-%H%M%S)
        backup='$REMOTE_CONFIG.backup-'\$stamp
        cp -p '$REMOTE_CONFIG' \"\$backup\"
        cat >'$REMOTE_CA.new'
        chmod 600 '$REMOTE_CA.new'
        mv '$REMOTE_CA.new' '$REMOTE_CA'
        printf '%s\n' \"\$backup\"
    " <"$TMP_DIR/ca.pem"
)
printf 'Backup: %s\n' "$BACKUP_PATH"

NETWORK_ID=$(
    remote "/usr/sbin/wpa_cli -i wlan0 list_networks |
        awk -F '\t' '\$2 == \"eduroam\" { print \$1; exit }'"
)
if [[ -z "$NETWORK_ID" ]]; then
    NETWORK_ID=$(remote '/usr/sbin/wpa_cli -i wlan0 add_network')
fi
[[ "$NETWORK_ID" =~ ^[[:digit:]]+$ ]] ||
    die "could not determine eduroam network id: $NETWORK_ID"

printf 'Writing secure eduroam profile as network id %s...\n' "$NETWORK_ID"
{
    printf 'set_network %s ssid %s\n' "$NETWORK_ID" "$(wpa_quote 'eduroam')"
    printf 'set_network %s key_mgmt WPA-EAP\n' "$NETWORK_ID"
    printf 'set_network %s eap PEAP\n' "$NETWORK_ID"
    printf 'set_network %s identity %s\n' "$NETWORK_ID" "$(wpa_quote "$USERNAME")"
    printf 'set_network %s anonymous_identity %s\n' "$NETWORK_ID" \
        "$(wpa_quote 'eduroam@stud.uni-stuttgart.de')"
    printf 'set_network %s password %s\n' "$NETWORK_ID" "$(wpa_quote "$PASSWORD")"
    printf 'set_network %s ca_cert %s\n' "$NETWORK_ID" "$(wpa_quote "$REMOTE_CA")"
    printf 'set_network %s altsubject_match %s\n' "$NETWORK_ID" \
        "$(wpa_quote 'DNS:eduroam.uni-stuttgart.de')"
    printf 'set_network %s phase1 %s\n' "$NETWORK_ID" \
        "$(wpa_quote 'tls_disable_tlsv1_0=0 tls_disable_tlsv1_1=0')"
    printf 'set_network %s phase2 %s\n' "$NETWORK_ID" "$(wpa_quote 'auth=MSCHAPV2')"
    printf 'set_network %s priority 2\n' "$NETWORK_ID"
    printf 'set_network %s ieee80211w 1\n' "$NETWORK_ID"
    printf 'enable_network %s\n' "$NETWORK_ID"
    if ((SKIP_CONNECT == 0)); then
        printf 'select_network %s\n' "$NETWORK_ID"
    fi
    printf 'save_config\n'
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
unset PASSWORD

printf 'Secure profile saved.\n'
if ((SKIP_CONNECT == 0)); then
    wait_for_eduroam
else
    printf 'Skipped connection test as requested.\n'
fi

printf '\nInstalled security fields:\n'
remote "
    /usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' anonymous_identity; printf '\n'
    /usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' ca_cert; printf '\n'
    /usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' altsubject_match; printf '\n'
"

printf '\nDone. Run ./verify.sh --negative-test on campus for a controlled server-name validation test.\n'
