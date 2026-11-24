#!/bin/sh
set -eu

root_device=$(findmnt -n -o SOURCE /)
case "$root_device" in
  /dev/mmcblk*p1) disk=${root_device%p1} ;;
  *) echo "Unsupported SD root device: $root_device" >&2; exit 1 ;;
esac

if growpart "$disk" 1; then
  :
else
  status=$?
  [ "$status" -eq 1 ] || exit "$status"
fi

part_name=${root_device##*/}
start=$(cat "/sys/class/block/$part_name/start")
size=$(cat "/sys/class/block/$part_name/size")
disk_sectors=$(blockdev --getsz "$disk")
[ "$((disk_sectors - start - size))" -le 20480 ] || {
  echo 'Root partition has not reached the end of the SD card' >&2
  exit 1
}

resize2fs "$root_device"
install -d /var/lib/debian-tegra
touch /var/lib/debian-tegra/root-expanded
