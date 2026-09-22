# Shared helpers for every script in this project. Sourced, never executed.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR

# shellcheck source=../config.env
source "$PROJECT_DIR/config.env"

# When VM_NAME is empty the directory name is used, so a renamed copy of this
# directory becomes a separate VM with no edit. libvirt rejects several
# characters in a domain name, so anything outside the allowed set becomes a
# hyphen.
if [[ -z "${VM_NAME:-}" ]]; then
  VM_NAME="$(basename "$PROJECT_DIR")"
fi
VM_NAME="$(printf '%s' "$VM_NAME" | tr -c 'A-Za-z0-9._-' '-')"
readonly VM_NAME

readonly NAME_MARKER="$PROJECT_DIR/.vm-name"
readonly TF_DIR="$PROJECT_DIR/terraform"
readonly ANSIBLE_DIR="$PROJECT_DIR/ansible"

log()  { printf '[%s] %s\n' "$VM_NAME" "$*" >&2; }
die()  { printf '[%s] error: %s\n' "$VM_NAME" "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed. This project is meant to run on the homelab host."
  done
}

v() { virsh -c "$LIBVIRT_URI" "$@"; }

# Refuses to act when the local Terraform state was created for a different VM.
# This is the failure mode of copying the directory after an apply: the copy
# inherits state pointing at the original VM, so `make down` in the copy would
# destroy the original. `make clone` avoids it, and this check catches a manual
# copy.
assert_state_matches() {
  [[ -f "$NAME_MARKER" ]] || return 0
  local recorded
  recorded="$(cat "$NAME_MARKER")"
  [[ "$recorded" == "$VM_NAME" ]] && return 0
  die "the Terraform state in this directory belongs to VM '$recorded', but this directory resolves to '$VM_NAME'.
  This happens when a directory is copied after 'make up'. Acting now would touch '$recorded', not '$VM_NAME'.
  Run 'make clean-state' to drop the inherited state (it does not touch any VM), then 'make up'."
}

record_state_owner() { printf '%s\n' "$VM_NAME" > "$NAME_MARKER"; }

domain_exists() { v dominfo "$VM_NAME" >/dev/null 2>&1; }

require_domain() {
  domain_exists || die "VM '$VM_NAME' does not exist. Run 'make up' first."
}

domain_state() { v domstate "$VM_NAME" 2>/dev/null | head -1 | tr -d '\r'; }

is_running() { [[ "$(domain_state)" == "running" ]]; }

# Host path of the VM's primary disk, read from libvirt rather than from
# Terraform state, so the snapshot and restore scripts work even if the state
# file was discarded.
disk_path() {
  v domblklist "$VM_NAME" --details 2>/dev/null \
    | awk '$1=="file" && $3=="vda" {print $4}' | head -1
}

# Extracts the first non-loopback IPv4 address out of a virsh table.
#
# The match is by shape, not by column position. Every one of these tables has
# a two-word column name in its header ("MAC address"), so a parser that reads
# field N treats the header row as data and returns the column title. That is
# what made `make ssh` try to connect to a host called "protocol".
_first_ipv4() {
  awk '{
    for (i = 1; i <= NF; i++)
      if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) {
        split($i, a, "/")
        if (a[1] !~ /^127\./) { print a[1]; exit }
      }
  }'
}

# The address is assigned by DHCP, so it has to be discovered. Three sources
# are tried in order of how current they are:
#
#   agent  the guest agent, which knows the address the guest actually holds
#   lease  libvirt's lease record for this domain, which needs no agent
#   table  the network-wide lease table, which still has the record during the
#          window when the domain's own view is empty
vm_ip_once() {
  local ip src mac
  for src in agent lease; do
    ip="$(v domifaddr "$VM_NAME" --source "$src" 2>/dev/null | _first_ipv4)"
    if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
  done

  mac="$(v domiflist "$VM_NAME" 2>/dev/null \
         | awk '{for (i=1;i<=NF;i++) if ($i ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/) {print $i; exit}}')"
  [[ -n "$mac" ]] || return 1

  ip="$(v net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -i -- "$mac" | _first_ipv4)"
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

# Waits for an address. $1 is the timeout in seconds, default 180. A first boot
# installs the guest agent, so it takes noticeably longer than a restart.
wait_for_ip() {
  local timeout="${1:-180}" waited=0 ip
  while (( waited < timeout )); do
    ip="$(vm_ip_once)"
    if [[ -n "$ip" ]]; then printf '%s\n' "$ip"; return 0; fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  return 1
}

wait_for_ssh() {
  local ip="$1" timeout="${2:-180}" waited=0
  while (( waited < timeout )); do
    if ssh_opts_run "$ip" true 2>/dev/null; then return 0; fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  return 1
}

# The VM is disposable and the network reuses addresses, so a recorded host key
# would be wrong most of the time. Host key checking is therefore off here, and
# it is off in ansible.cfg for the same reason.
ssh_opts_run() {
  local ip="$1"; shift
  ssh -i "$SSH_PRIVATE_KEY" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "$SSH_USER@$ip" "$@"
}

# Stops the guest cleanly, then forces it off if it has not stopped within
# SHUTDOWN_TIMEOUT. Returns 0 whether or not the force was needed.
stop_domain() {
  is_running || return 0
  log "asking the guest to shut down"
  v shutdown "$VM_NAME" >/dev/null
  local waited=0
  while is_running && (( waited < SHUTDOWN_TIMEOUT )); do
    sleep 2
    waited=$(( waited + 2 ))
  done
  if is_running; then
    log "guest did not stop within ${SHUTDOWN_TIMEOUT}s, forcing power off"
    v destroy "$VM_NAME" >/dev/null
  fi
}

# Resolves a possibly relative path against the project directory, so a
# relative SNAPSHOT_DIR stays inside the copy it belongs to.
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    ~*) printf '%s' "${1/#\~/$HOME}" ;;
    *)  printf '%s/%s' "$PROJECT_DIR" "$1" ;;
  esac
}

# Terraform reads every setting from config.env through these variables, so
# config.env stays the single place to change anything.
export_tf_vars() {
  export TF_VAR_vm_name="$VM_NAME"
  export TF_VAR_vcpu="$VCPU"
  export TF_VAR_memory_mb="$MEMORY_MB"
  export TF_VAR_disk_gb="$DISK_GB"
  export TF_VAR_base_image_url="$BASE_IMAGE_URL"
  export TF_VAR_libvirt_uri="$LIBVIRT_URI"
  export TF_VAR_storage_pool="$STORAGE_POOL"
  export TF_VAR_network_name="$NETWORK_NAME"
  export TF_VAR_ssh_user="$SSH_USER"
  export TF_VAR_ssh_public_key_path="$SSH_PUBLIC_KEY"
}
