# Repository Notes

## Purpose

This repository configures a reMarkable 2 for the University of Stuttgart
student eduroam profile. Keep the public README short and installation-first.
Technical background and maintenance notes belong in this file.

The setup was tested on a reMarkable 2 running reMarkable OS `3.27.1.0`.

## Scope

The scripts intentionally support only University of Stuttgart student
accounts:

```text
st123456@stud.uni-stuttgart.de
```

Staff and guest profiles have different outer identities and are not supported.

## Security Model

The built-in reMarkable Wi-Fi form can configure `PEAP` and `MSCHAPV2`, but it
does not expose CA validation and RADIUS server name matching. Without these
checks, a malicious access point can impersonate eduroam and attempt to obtain
credentials.

The installer adds the fields required by the current University of Stuttgart
CAT profile:

```text
ca_cert="/home/root/.config/remarkable/eduroam-uni-stuttgart-ca.pem"
altsubject_match="DNS:eduroam.uni-stuttgart.de"
```

The CA bundle is downloaded from the official eduroam CAT profile during every
installation. The installer validates the expected Uni Stuttgart parameters and
aborts if the profile changes.

The SIAM password is stored in plain text in the root-owned Wi-Fi configuration
on the tablet. This is also how the stock reMarkable Wi-Fi service stores
network credentials. The installer reads the password without terminal echo and
does not write it to a file on the host computer.

## Device Integration

The scripts use the stock `wpa_supplicant` service already shipped with recent
reMarkable OS versions. Do not add another Wi-Fi service or modify files under
`/etc`.

Persistent files:

```text
/home/root/.config/remarkable/wifi_networks.conf
/home/root/.config/remarkable/eduroam-uni-stuttgart-ca.pem
```

Files under `/home/root` survive normal OS updates more reliably than files
under `/etc`. The stock service may recreate `wifi_networks.conf` with mode
`0644` when it saves the file. This matches the device's default behavior and
is acceptable.

The default USB SSH destination is:

```text
root@10.11.99.1
```

## WLB Captive Portal

`setup-wlb.sh` configures the open WLB Stuttgart SSID:

```text
wifi@wlb
```

The captive portal redirects HTTP traffic to:

```text
https://gate.wlb-stuttgart.de/
```

The form fields observed on 2026-06-22 were:

```text
tosaccept=tosaccept
username=<Ausweisnummer>
password:<Passwort>
login=login
```

Do not pass WLB credentials as command-line arguments. The script reads them
locally, URL-encodes them, transfers them over SSH stdin, writes them to a
temporary `0600` post body on the tablet, and deletes that file immediately
after the request. If the script is launched without an interactive terminal,
it uses `WLB_ASKPASS`, `SSH_ASKPASS`, or `/usr/lib/git-core/git-gui--askpass`
for local GUI prompts.

`install-wlb-autologin.sh` installs a systemd timer on the tablet. It stores an
URL-encoded POST body in:

```text
/home/root/.config/remarkable/wlb-captive.env
```

The file must remain `0600 root:root`. The installed script checks that the
tablet is currently connected to `wifi@wlb`, confirms the connectivity check is
redirecting to `gate.wlb-stuttgart.de`, and only then posts the stored login
body. The timer runs every five minutes:

```text
/etc/systemd/system/wlb-captive-login.service
/etc/systemd/system/wlb-captive-login.timer
```

For first-time access, the root password is shown on the tablet under a path
similar to:

```text
Settings -> Help -> About -> Copyright and licenses -> GPLv3 Compliance
```

The exact menu path varies between reMarkable OS versions. Setting up an SSH key
is recommended. See the
[reMarkable SSH guide](https://remarkable.guide/guide/access/ssh.html).

## Verification

Before publishing script changes, run:

```bash
bash -n setup-uni-stuttgart-student.sh verify.sh
./verify.sh
./verify.sh --negative-test
```

The negative test temporarily installs an intentionally invalid RADIUS server
name. It must fail with `AltSubject mismatch`, restore
`DNS:eduroam.uni-stuttgart.de`, reconnect, acquire DHCP, and reach the internet.

Re-run `./verify.sh` after reMarkable OS updates.

## References

- [University of Stuttgart eduroam instructions](https://www.tik.uni-stuttgart.de/support/anleitungen/wlan-eduroam/)
- [University of Stuttgart eduroam CAT profile](https://cat.eduroam.org/?idp=5006)
- [reMarkable SSH guide](https://remarkable.guide/guide/access/ssh.html)
