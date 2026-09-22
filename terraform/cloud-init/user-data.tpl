#cloud-config
hostname: ${hostname}
manage_etc_hosts: true

users:
  - name: ${ssh_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

# Grow the root filesystem to the full disk size requested in config.env. The
# cloud image ships a small partition, so without this the guest would ignore
# most of the disk.
growpart:
  mode: auto
  devices: ["/"]
resize_rootfs: true

package_update: true
package_upgrade: false

# qemu-guest-agent is required, not optional: the address is assigned by DHCP,
# so the scripts ask the agent for it. Without the agent they fall back to the
# network's DHCP lease table, which is slower to settle.
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
