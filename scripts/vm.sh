#!/usr/bin/env bash
#
# Lifecycle of the sandbox VM. The Makefile is a thin wrapper around this
# script, so every operation is also available directly:
#
#   scripts/vm.sh up | start | stop | restart | down | status | ip | ssh [cmd]
#
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat >&2 <<USAGE
usage: vm.sh <command> [args]

  up        create the VM with Terraform and wait until it answers over SSH
  start     power on an existing, stopped VM
  stop      shut the guest down cleanly
  restart   stop then start
  down      destroy the VM and every volume Terraform created for it
  status    print name, state, address and disk path
  name      print the VM name this directory resolves to
  ip        print the VM's address, nothing else
  ssh       open a shell in the VM, or run the given command in it
USAGE
  exit 2
}

cmd_up() {
  require_cmd terraform virsh
  assert_state_matches
  export_tf_vars

  if [[ ! -d "$TF_DIR/.terraform" ]]; then
    log "initialising Terraform"
    terraform -chdir="$TF_DIR" init -input=false
  fi

  log "creating VM: ${VCPU} vCPU, ${MEMORY_MB} MiB RAM, ${DISK_GB} GiB disk"
  terraform -chdir="$TF_DIR" apply -input=false -auto-approve
  record_state_owner

  log "waiting for the guest agent to report an address (first boot installs it, so this takes a few minutes)"
  local ip
  ip="$(wait_for_ip 300)" || die "the VM started but never reported an address. Check 'virsh -c $LIBVIRT_URI console $VM_NAME'."
  log "address: $ip"

  log "waiting for SSH"
  wait_for_ssh "$ip" 180 || die "no SSH on $ip. The key in SSH_PUBLIC_KEY may not match SSH_PRIVATE_KEY."
  log "ready: ssh $SSH_USER@$ip"
}

cmd_start() {
  require_domain
  if is_running; then log "already running"; else v start "$VM_NAME" >/dev/null; log "started"; fi
  local ip; ip="$(wait_for_ip 120)" || die "started, but no address yet"
  log "address: $ip"
}

cmd_stop() {
  require_domain
  stop_domain
  log "stopped"
}

cmd_restart() { cmd_stop; cmd_start; }

cmd_down() {
  require_cmd terraform
  assert_state_matches
  export_tf_vars
  [[ -d "$TF_DIR/.terraform" ]] || die "no Terraform state here, so there is nothing this directory owns to destroy."
  log "destroying the VM and its volumes"
  terraform -chdir="$TF_DIR" destroy -input=false -auto-approve
  rm -f "$NAME_MARKER" "$ANSIBLE_DIR/inventory.ini"
  log "destroyed"
}

cmd_status() {
  printf 'name:   %s\n' "$VM_NAME"
  if ! domain_exists; then printf 'state:  absent\n'; return 0; fi
  printf 'state:  %s\n' "$(domain_state)"
  printf 'cpu:    %s vcpu\n' "$(v dominfo "$VM_NAME" | awk -F': *' '/^CPU\(s\)/ {print $2}')"
  printf 'memory: %s\n'      "$(v dominfo "$VM_NAME" | awk -F': *' '/^Max memory/ {print $2}')"
  printf 'disk:   %s\n'      "$(disk_path)"
  printf 'address: %s\n'     "$(vm_ip_once || echo 'not reported yet')"
}

cmd_name() { printf '%s\n' "$VM_NAME"; }

cmd_ip() {
  require_domain
  local ip; ip="$(vm_ip_once)"
  [[ -n "$ip" ]] || die "no address reported. Is the VM running?"
  printf '%s\n' "$ip"
}

cmd_ssh() {
  require_domain
  local ip; ip="$(cmd_ip)"
  if (( $# == 0 )); then
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR "$SSH_USER@$ip"
  else
    ssh_opts_run "$ip" "$@"
  fi
}

(( $# >= 1 )) || usage
command="$1"; shift
case "$command" in
  up)      cmd_up "$@" ;;
  start)   cmd_start "$@" ;;
  stop)    cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  down)    cmd_down "$@" ;;
  status)  cmd_status "$@" ;;
  name)    cmd_name "$@" ;;
  ip)      cmd_ip "$@" ;;
  ssh)     cmd_ssh "$@" ;;
  *)       usage ;;
esac
