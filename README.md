# eduroam on a reMarkable 2 at the University of Stuttgart

This repository configures a reMarkable 2 for the University of Stuttgart
student eduroam profile. It uses the stock `wpa_supplicant` service already
shipped with recent reMarkable OS versions. It does not install another Wi-Fi
service or modify files under `/etc`.

The setup was tested on a reMarkable 2 running reMarkable OS `3.27.1.0`.

## Security model

The built-in reMarkable Wi-Fi form can configure `PEAP` and `MSCHAPV2`, but it
does not expose fields for CA validation and RADIUS server name matching.
Without those checks, a malicious access point can impersonate eduroam and
attempt to obtain your credentials.

The installer adds both checks required by the current University of Stuttgart
CAT profile:

```text
ca_cert="/home/root/.config/remarkable/eduroam-uni-stuttgart-ca.pem"
altsubject_match="DNS:eduroam.uni-stuttgart.de"
```

The CA bundle is downloaded from the official eduroam CAT profile during every
installation. The installer validates the expected Uni Stuttgart parameters and
aborts if that profile changes.

Your SIAM password is stored in plain text in the root-owned Wi-Fi
configuration on the tablet. This is how the stock reMarkable Wi-Fi service
stores network credentials. The installer reads the password without terminal
echo and does not write it to a file on your computer.

## Scope

The scripts intentionally support only University of Stuttgart student
accounts:

```text
st123456@stud.uni-stuttgart.de
```

Staff and guest profiles have different outer identities and are not supported
by this installer.

## Prerequisites

- A reMarkable 2 connected to your computer by USB
- Internet access on your computer while running the installer
- `bash`, `curl`, `ssh`, `awk`, and `grep`
- Access to the tablet as `root@10.11.99.1`
- An eduroam access point in range for the final connection test

Test SSH access first:

```bash
ssh root@10.11.99.1
```

The root password is shown on the tablet under:

```text
Settings -> Help -> About -> Copyright and licenses -> GPLv3 Compliance
```

The exact path varies slightly between reMarkable OS versions. Setting up an SSH
key is recommended. See the
[reMarkable SSH guide](https://remarkable.guide/guide/access/ssh.html).

## Install

Run:

```bash
./setup-uni-stuttgart-student.sh
```

The script prompts for your full student identity and SIAM password. It then:

1. Downloads and validates the current official CAT profile.
2. Opens one reusable SSH connection to the tablet.
3. Saves a timestamped backup of the existing Wi-Fi configuration.
4. Installs the official CA bundle under `/home/root`.
5. Creates or updates the stock `eduroam` network profile.
6. Selects eduroam and verifies EAP authentication, DHCP, and internet access.

To use another SSH destination:

```bash
./setup-uni-stuttgart-student.sh --target root@remarkable
```

If the tablet is not currently in range of eduroam, configure it without the
online test:

```bash
./setup-uni-stuttgart-student.sh --skip-connect
```

## Verify

Check the installed security fields and current connection:

```bash
./verify.sh
```

For a controlled negative test, temporarily configure an invalid expected
RADIUS server name:

```bash
./verify.sh --negative-test
```

The negative test must fail with `AltSubject mismatch`. The script immediately
restores `DNS:eduroam.uni-stuttgart.de`, reconnects, and checks that EAP succeeds
again.

## Roll back

The installer prints the backup path it created. To restore a backup:

```bash
ssh root@10.11.99.1 \
  'cp -p /home/root/.config/remarkable/wifi_networks.conf.backup-YYYYMMDD-HHMMSS \
    /home/root/.config/remarkable/wifi_networks.conf &&
   systemctl restart wpa_supplicant.service'
```

Replace the timestamp with the backup printed by the installer.

## Notes

- Files under `/home/root` survive normal OS updates more reliably than files
  under `/etc`. Re-run `./verify.sh` after an update.
- The stock service may recreate `wifi_networks.conf` with mode `0644` when it
  saves the file. This matches the device's default behavior.
- The official Uni Stuttgart instructions are available at
  [tik.uni-stuttgart.de](https://www.tik.uni-stuttgart.de/support/anleitungen/wlan-eduroam/).
