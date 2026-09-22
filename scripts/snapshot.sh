#!/usr/bin/env bash
#
# Saves a standalone copy of the VM disk into a directory. The file name
# carries the moment the snapshot was taken, in the format YYYYMMDDTHHMMSS:
#
#   <vm-name>-20260922T143005.qcow2
#
# The copy is flattened with 'qemu-img convert', so it carries no reference to
# the base image and can be moved to another host on its own.
#
# The guest is shut down first, because copying the disk of a running guest
# yields the on-disk state of a machine that was never shut down cleanly, which
# can mean a corrupt filesystem in the copy. The VM is started again afterwards
# if it was running, unless --keep-off is given.
#
#   scripts/snapshot.sh [DIRECTORY] [--keep-off]
#
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dest=""
keep_off=0
for arg in "$@"; do
  case "$arg" in
    --keep-off) keep_off=1 ;;
    -h|--help)  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    -*)         die "unknown option: $arg" ;;
    *)          [[ -z "$dest" ]] || die "give at most one directory"; dest="$arg" ;;
  esac
done

require_cmd virsh qemu-img
require_domain

dest="$(abs_path "${dest:-$SNAPSHOT_DIR}")"
mkdir -p "$dest"

disk="$(disk_path)"
[[ -n "$disk" ]] || die "could not determine the VM's disk path from libvirt"

was_running=0
if is_running; then was_running=1; stop_domain; fi

stamp="$(date +%Y%m%dT%H%M%S)"
out="$dest/${VM_NAME}-${stamp}.qcow2"

# The disks in the pool are readable by root only, so the copy runs under sudo
# and the result is handed back to the invoking account.
log "writing $out"
sudo qemu-img convert -O qcow2 -p "$disk" "$out.part"
sudo mv "$out.part" "$out"
sudo chown "$(id -u):$(id -g)" "$out"
chmod 0644 "$out"

if (( was_running && ! keep_off )); then
  log "starting the VM again"
  v start "$VM_NAME" >/dev/null
fi

log "snapshot complete: $out ($(du -h "$out" | cut -f1))"
printf '%s\n' "$out"
