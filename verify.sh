#!/usr/bin/env bash
set -euo pipefail

TARGET='root@10.11.99.1'
NEGATIVE_TEST=0
REMOTE_CONFIG='/home/root/.config/remarkable/wifi_networks.conf'
REMOTE_CA='/home/root/.config/remarkable/eduroam-uni-stuttgart-ca.pem'

usage() {
    cat <<'EOF'
Usage: ./verify.sh [options]

Verify the secure University of Stuttgart eduroam profile on a reMarkable 2.

Options:
  --target USER@HOST   SSH destination (default: root@10.11.99.1)
  --negative-test      Prove that an invalid RADIUS server name is rejected
  -h, --help           Show this help
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --target)
            (($# >= 2)) || die '--target requires a value'
            TARGET=$2
            shift 2
            ;;
        --negative-test)
            NEGATIVE_TEST=1
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

command -v ssh >/dev/null 2>&1 || die 'required command not found: ssh'

SSH=(
    ssh
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=accept-new
    "$TARGET"
)

NETWORK_ID=$(
    "${SSH[@]}" "/usr/sbin/wpa_cli -i wlan0 list_networks |
        awk -F '\t' '\$2 == \"eduroam\" { print \$1; exit }'"
)
[[ "$NETWORK_ID" =~ ^[[:digit:]]+$ ]] || die 'eduroam network profile not found'

printf '%s\n' '-- installed security fields --'
"${SSH[@]}" "
    set -eu
    test -s '$REMOTE_CA'
    test \"\$(grep -c '^-----BEGIN CERTIFICATE-----$' '$REMOTE_CA')\" = 2
    test \"\$(/usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' anonymous_identity)\" = '\"eduroam@stud.uni-stuttgart.de\"'
    test \"\$(/usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' ca_cert)\" = '\"$REMOTE_CA\"'
    test \"\$(/usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' altsubject_match)\" = '\"DNS:eduroam.uni-stuttgart.de\"'
    /usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' anonymous_identity; printf '\n'
    /usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' ca_cert; printf '\n'
    /usr/sbin/wpa_cli -i wlan0 get_network '$NETWORK_ID' altsubject_match; printf '\n'
    printf 'ca-certificates='
    grep -c '^-----BEGIN CERTIFICATE-----$' '$REMOTE_CA'
    printf 'config='
    stat -c '%a %U:%G %n' '$REMOTE_CONFIG'
    printf 'ca-bundle='
    stat -c '%a %U:%G %n' '$REMOTE_CA'
"

if ((NEGATIVE_TEST)); then
    printf '\n%s\n' '-- controlled negative server-name test --'
    "${SSH[@]}" "sh -s -- '$NETWORK_ID'" <<'EOF'
set -eu

network_id=$1
correct_match='"DNS:eduroam.uni-stuttgart.de"'

restore() {
    /usr/sbin/wpa_cli -i wlan0 set_network "$network_id" altsubject_match "$correct_match" >/dev/null || true
    /usr/sbin/wpa_cli -i wlan0 enable_network "$network_id" >/dev/null || true
    /usr/sbin/wpa_cli -i wlan0 select_network "$network_id" >/dev/null || true
}
trap restore EXIT INT TERM

/usr/sbin/wpa_cli -i wlan0 set_network "$network_id" altsubject_match '"DNS:intentionally-invalid.example"' >/dev/null
since=$(date '+%Y-%m-%d %H:%M:%S')
/usr/sbin/wpa_cli -i wlan0 reassociate >/dev/null

negative_test_passed=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if journalctl -u wpa_supplicant.service --since "$since" --no-pager |
        grep -Fq "AltSubject mismatch"; then
        negative_test_passed=1
        break
    fi
    sleep 2
done

if [ "$negative_test_passed" = 1 ]; then
    printf '%s\n' 'PASS: invalid server name was rejected with AltSubject mismatch'
else
    printf '%s\n' 'FAIL: expected AltSubject mismatch was not observed' >&2
    exit 1
fi

restore
trap - EXIT INT TERM

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    status=$(/usr/sbin/wpa_cli -i wlan0 status)
    if printf '%s\n' "$status" | grep -Fq 'ssid=eduroam' &&
        printf '%s\n' "$status" | grep -Fq 'wpa_state=COMPLETED' &&
        printf '%s\n' "$status" | grep -Fq 'EAP state=SUCCESS'; then
        printf '%s\n' 'PASS: restored the correct server name and reconnected'
        exit 0
    fi
    sleep 2
done

printf '%s\n' 'FAIL: did not reconnect after restoring the correct server name' >&2
exit 1
EOF
fi

printf '\n%s\n' '-- live connection --'
"${SSH[@]}" '
    for _ in 1 2 3 4 5 6 7 8; do
        if ip -4 addr show dev wlan0 | grep -q "inet "; then
            break
        fi
        sleep 2
    done
    ip -4 addr show dev wlan0 | grep -q "inet " ||
        {
            printf "%s\n" "DHCP did not provide an IPv4 address" >&2
            exit 1
        }
    /usr/sbin/wpa_cli -i wlan0 status |
        grep -E "^(ssid|wpa_state|ip_address|EAP state|selectedMethod|eap_tls_version|EAP TLS cipher|EAP-PEAPv0 Phase2 method)="
'

printf '\n%s\n' '-- internet connectivity --'
"${SSH[@]}" 'ping -c 1 -W 3 1.1.1.1'

printf '\nVerification passed.\n'
