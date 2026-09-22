#!/usr/bin/env bash
#
# Puts a snapshot back in place of the VM's current disk:
#
#   scripts/restore.sh <snapshot.qcow2>
#
# The current disk content is overwritten and is not recoverable, so the script
# asks for confirmation unless --yes is given. The VM is shut down first and is
# left off, so the next 'make start' boots the restored disk.
#
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

snapshot=""
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  assume_yes=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    -*)        die "unknown option: $arg" ;;
    *)         [[ -z "$snapshot" ]] || die "give exactly one snapshot file"; snapshot="$arg" ;;
  esac
done

[[ -n "$snapshot" ]] || die "give the snapshot file to restore"
[[ -f "$snapshot" ]] || die "no such file: $snapshot"

require_cmd virsh qemu-img
require_domain

disk="$(disk_path)"
[[ -n "$disk" ]] || die "could not determine the VM's disk path from libvirt"

if (( ! assume_yes )); then
  printf 'This overwrites %s with %s. The current content is lost. Continue? [y/N] ' "$disk" "$snapshot" >&2
  read -r reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "cancelled"
fi

stop_domain

log "restoring $snapshot"
sudo qemu-img convert -O qcow2 -p "$snapshot" "$disk.restoring"
sudo mv "$disk.restoring" "$disk"
# libvirt takes ownership of the disk again when the domain starts, so root
# ownership and 0600 here are correct and deliberate.
sudo chown root:root "$disk"
sudo chmod 0600 "$disk"

log "restored. The VM is off; run 'make start' to boot it."
