# Design decisions

Date: 2026-09-22

Decisions taken while building this project, with the reason for each. They are
recorded because several of them look arbitrary from the code alone.

## The VM name comes from the directory name

`VM_NAME` in `config.env` ships empty, and `scripts/lib.sh` falls back to
`basename "$PROJECT_DIR"`. Every libvirt object is then derived from that name:
the domain, `<name>.qcow2`, `<name>-base.qcow2` and `<name>-cloudinit.iso`.

The requirement was that copying the directory and renaming the copy yields a
second sandbox. Deriving the name from the directory satisfies it with zero
edits. Any character outside `[A-Za-z0-9._-]` is replaced by a hyphen, because
libvirt rejects a domain name containing others.

## Copying carries a hazard, so there is a guard

Terraform keeps its state in the project directory. A copy taken after
`make up` therefore inherits state describing the original VM, so `make down`
in the copy would destroy the original. Two measures address this:

1. `make clone NAME=x` copies the directory while excluding the state, the
   state marker, the generated inventory and the snapshots.
2. `scripts/vm.sh` writes the VM name into `.vm-name` after a successful
   apply, and refuses to run when that file disagrees with the directory name.
   This catches a manual `cp -r`, which measure 1 cannot.

## The pool and the network are referenced, never declared

`~/homelab/k8s/terraform` declares `libvirt_pool.k8s` with name `default` at
`/pool`, and the cluster attaches to the `default` network. If this project
also declared them, then `terraform destroy` here would attempt to remove
host-wide resources the running cluster depends on.

So `main.tf` contains no `libvirt_pool` resource and no `libvirt_network`
resource. It names both in variables and uses them.

## The base image is per sandbox

The k8s project owns a volume called `ubuntu-base.qcow2` in the same pool, and
every cluster disk uses it as a copy-on-write backing store. Deleting it would
break those VMs. A sandbox must therefore never create or destroy a volume
under that name, so the base image here is `<vm-name>-base.qcow2`.

The consequence is roughly 600 MiB of image per sandbox instead of one shared
copy. A shared image was rejected for a second reason as well: two sandboxes
with separate Terraform states cannot both manage one volume, so the second
`apply` would fail.

## DHCP, not a static address

The k8s project assigns static addresses through an `ip_octet` per node. A
sandbox cannot do that, because the octet would have to be unique per copy, so
copying the directory would require an edit and two copies could collide.

The VM therefore takes a DHCP lease, and the address is discovered at run time.
`scripts/lib.sh` tries three sources in order: the guest agent, libvirt's
lease record for the domain (`domifaddr --source lease`), and the
network-wide lease table. Only the first needs the agent, so address
discovery keeps working when the agent is unavailable.

## Snapshots are taken with the guest stopped

`scripts/snapshot.sh` shuts the guest down, copies the disk, then starts it
again if it had been running. Copying the disk of a running guest captures the
state of a machine that was never shut down cleanly, which can mean a corrupt
filesystem inside the copy.

The alternative, an atomic overlay via `virsh snapshot-create-as --disk-only`
followed by a block commit, avoids the downtime but adds a failure mode that
leaves the domain pointing at an overlay if it is interrupted. For a sandbox
that is expected to be stopped and started constantly, the simpler behaviour
was preferred. `--keep-off` skips the restart.

The copy is flattened with `qemu-img convert -O qcow2`, so it carries no
reference to the base image and can be moved to another host on its own. The
disks in `/pool` are readable by root only, so the copy runs under `sudo` and
the result is handed to the invoking account.

## The copy targets use tar, not rsync

`rsync` is not installed on `homelab`, and `make sync` and `make clone` must
work there as well as on the workstation. `tar` is present on both.

## Two defects found on the first run, and their fixes

The first `make up` created the VM correctly, but `make ssh` failed with
`Could not resolve hostname protocol`.

### Parsing virsh tables by column position

`vm_ip_once` read field 5 of `virsh domiflist` to get the MAC, and field 5 of
`virsh net-dhcp-leases` to get the address. Both tables have a header row whose
column name `MAC address` is two words, so the header row parses as five or
more fields and is indistinguishable from data by index. The MAC therefore came
out as the literal string `MAC`, which then matched the leases header row, whose
field 5 is `Protocol`. That string reached `ssh` as a host name.

The fix is to match by shape rather than by position: `_first_ipv4` scans every
field of every line for something shaped like an IPv4 address and skips
loopback, and the MAC is found by a MAC-shaped regex. A header row contains
neither, so it cannot be mistaken for data.

### The guest agent channel rendered as a pty

`virsh domifaddr --source agent` reported `guest agent is not responding`, even
though `qemu-guest-agent` was active inside the guest and
`/dev/virtio-ports/org.qemu.guest_agent.0` existed. The domain XML showed
`<channel type='pty'>`: the Terraform channel block declared the virtio target
but no source, so libvirt had no socket on which to reach the agent.

The fix is `source = { unix = { mode = "bind" } }` in the channel block, with
the path left unset so libvirt chooses its own location.

This defect only degraded the project rather than breaking it, because the
lease sources need no agent. It was masked entirely until the parsing defect
above exposed the fallback path.

## Current status

The VM has been created, and `make status`, `make ip` and `make ssh` all work
against it: Ubuntu 24.04.5 LTS, 2 vCPU, 3916 MiB RAM, 15 GiB root filesystem
grown from the 16 GiB disk.

The guest agent fix is in `terraform/main.tf` but is not yet applied, so the
running VM still has a pty channel and still answers from the lease sources.
A `make down && make up`, or a `terraform apply`, picks it up.

Still unexercised: `make provision`, `make snapshot`, `make restore` and
`make clone`.
