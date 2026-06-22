# eduroam on a reMarkable 2 at the University of Stuttgart

Configure a reMarkable 2 for the University of Stuttgart student eduroam
profile with CA and RADIUS server name validation.

## Install

Connect the reMarkable 2 by USB, then run:

```bash
./setup-uni-stuttgart-student.sh
```

For the WLB Stuttgart captive portal:

```bash
./setup-wlb.sh
```

The script prompts for your student identity and SIAM password. Use the full
identity:

```text
st123456@stud.uni-stuttgart.de
```

To use another SSH destination:

```bash
./setup-uni-stuttgart-student.sh --target root@remarkable
```

If the tablet is not currently in range of eduroam:

```bash
./setup-uni-stuttgart-student.sh --skip-connect
```

## Verify

```bash
./verify.sh
```

To prove that an invalid RADIUS server name is rejected and then restore the
working configuration:

```bash
./verify.sh --negative-test
```

## Roll back

The installer prints the backup path it created. Restore that backup with:

```bash
ssh root@10.11.99.1 \
  'cp -p /home/root/.config/remarkable/wifi_networks.conf.backup-YYYYMMDD-HHMMSS \
    /home/root/.config/remarkable/wifi_networks.conf &&
   systemctl restart wpa_supplicant.service'
```

Replace the timestamp with the backup printed by the installer.
