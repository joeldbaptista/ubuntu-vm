terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# The storage pool and the network are host-wide resources that already exist
# on homelab and are shared with the k8s project. They are referenced by name
# only: declaring them here would make `terraform destroy` in this sandbox tear
# down infrastructure that other projects depend on.

# Base cloud image for this sandbox. The name is prefixed with the VM name on
# purpose. The k8s project owns a volume called "ubuntu-base.qcow2" in the same
# pool, and every cluster disk uses it as a backing store, so a sandbox must
# never create or delete a volume under that name.
resource "libvirt_volume" "base" {
  name = "${var.vm_name}-base.qcow2"
  pool = var.storage_pool
  target = {
    format = { type = "qcow2" }
  }
  create = {
    content = { url = var.base_image_url }
  }
}

# The VM disk, copy-on-write on top of the base image, grown to the requested
# size. cloud-init expands the root filesystem to fill it on first boot.
resource "libvirt_volume" "disk" {
  name     = "${var.vm_name}.qcow2"
  pool     = var.storage_pool
  capacity = var.disk_gb * 1024 * 1024 * 1024
  target = {
    format = { type = "qcow2" }
  }
  backing_store = {
    path   = libvirt_volume.base.path
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "seed" {
  name = "${var.vm_name}-cloudinit"

  meta_data = yamlencode({
    "instance-id"    = var.vm_name
    "local-hostname" = var.vm_name
  })

  user_data = templatefile("${path.module}/cloud-init/user-data.tpl", {
    hostname       = var.vm_name
    ssh_user       = var.ssh_user
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })

  # DHCP rather than a static address. A static octet would have to be unique
  # per sandbox, so copying this directory would need a manual edit and two
  # copies could collide on the same address.
  network_config = file("${path.module}/cloud-init/network-config.yaml")
}

resource "libvirt_volume" "seed" {
  name = "${var.vm_name}-cloudinit.iso"
  pool = var.storage_pool
  target = {
    format = { type = "iso" }
  }
  create = {
    content = { url = libvirt_cloudinit_disk.seed.path }
  }
}

resource "libvirt_domain" "vm" {
  name        = var.vm_name
  type        = "kvm"
  memory      = var.memory_mb
  memory_unit = "MiB"
  vcpu        = var.vcpu
  running     = true

  # host-passthrough exposes the host's real CPU features to the guest. The
  # conservative default model lacks SSE4.2/AVX2, which makes prebuilt Python
  # wheels crash at import time. This is the same reason the k8s project uses
  # it, and a sandbox is meant to reproduce what the cluster does.
  cpu = {
    mode  = "host-passthrough"
    check = "none"
  }

  os = {
    type      = "hvm"
    type_arch = "x86_64"
    boot_devices = [
      { dev = "hd" }
    ]
  }

  devices = {
    disks = [
      {
        device = "disk"
        source = {
          file = { file = libvirt_volume.disk.path }
        }
        target = { dev = "vda", bus = "virtio" }
        driver = { name = "qemu", type = "qcow2" }
      },
      {
        device = "cdrom"
        source = {
          file = { file = libvirt_volume.seed.path }
        }
        target = { dev = "hdc", bus = "ide" }
        driver = { name = "qemu", type = "raw" }
      }
    ]
    interfaces = [
      {
        model  = { type = "virtio" }
        source = { network = { network = var.network_name } }
      }
    ]
    # The guest agent channel. scripts/lib.sh asks the agent for the VM's
    # address, because with DHCP the address is not known in advance.
    #
    # The unix source is required, not decoration. Without it the channel
    # renders as type='pty', and libvirt then has no socket on which to reach
    # the agent: the agent runs in the guest, but every `virsh domifaddr
    # --source agent` fails with "guest agent is not responding". Leaving the
    # path unset lets libvirt place the socket where it expects it.
    channels = [
      {
        source = {
          unix = { mode = "bind" }
        }
        target = {
          virt_io = { name = "org.qemu.guest_agent.0" }
        }
      }
    ]
  }
}
