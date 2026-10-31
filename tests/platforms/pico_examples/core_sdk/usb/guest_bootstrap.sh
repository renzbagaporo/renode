#!/bin/bash
# Runs only in the isolated USB/IP guest; mounts only task-owned shares.
set -euo pipefail
mkdir -p /mnt/helpers /mnt/guest_outputs
mountpoint -q /mnt/helpers || mount -t 9p -o trans=virtio,version=9p2000.L,ro helpers /mnt/helpers
mountpoint -q /mnt/guest_outputs || mount -t 9p -o trans=virtio,version=9p2000.L guest_outputs /mnt/guest_outputs
modprobe vhci-hcd
modprobe cdc-acm
printf '\nPICO_USB_HOST_READY\n'
exec /bin/bash --noprofile --norc
