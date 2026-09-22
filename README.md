# virtual-sandbox

A disposable Ubuntu Server VM on `homelab`, created with Terraform, configured
with Ansible, and driven through `make`. It exists to be played with, broken,
snapshotted and thrown away.

The VM is 2 vCPU, 4 GiB RAM and a 16 GiB disk by default, running the current
Ubuntu Server cloud image.

## Copying this directory is the intended way to get another sandbox

Nothing in this project hardcodes the VM name. When `VM_NAME` in `config.env`
is empty, which is how it ships, the name of the directory is used instead. So:

```
make clone NAME=kafka-test
cd ../kafka-test
make all
```

creates a second, fully independent VM called `kafka-test`, with its own disk,
its own cloud-init seed, its own Terraform state and its own snapshots. No file
needs editing.

Use `make clone` rather than `cp -r`. A plain copy taken after `make up` also
copies the Terraform state, and that state points at the original VM, so
`make down` in the copy would destroy the original. `make clone` excludes the
state. A manual copy is caught as well: the scripts record which VM the state
belongs to and refuse to run when it disagrees with the directory name.

## Where this runs

On `homelab`. The scripts need `virsh` and `qemu-img`, which are installed
there and not on the workstation. The workstation holds the source, and
`make sync` copies it over:

```
make sync                       # rsync to homelab:projects/virtual-sandbox/
ssh homelab
cd projects/virtual-sandbox
make all
```

## Usage

```
make all          # create the VM, then configure it
make ssh          # shell into it
make snapshot     # save a timestamped copy of its disk
make down         # destroy it
```

`make help` lists every target. Each one is a wrapper around a script in
`scripts/`, so the same operations are available without `make`:

| Target | Script | Does |
| --- | --- | --- |
| `make up` | `scripts/vm.sh up` | Terraform apply, then wait for SSH |
| `make provision` | `scripts/inventory.sh` + `ansible-playbook` | Apply `ansible/site.yml` |
| `make start` / `stop` / `restart` | `scripts/vm.sh …` | Power control |
| `make down` | `scripts/vm.sh down` | Terraform destroy |
| `make status` / `ip` / `ssh` | `scripts/vm.sh …` | Inspect and log in |
| `make snapshot` | `scripts/snapshot.sh` | Timestamped disk copy |
| `make restore` | `scripts/restore.sh` | Put a snapshot back |
| `make clone` | `rsync` | New sandbox from this one |

## Snapshots

`make snapshot` writes `snapshots/<vm-name>-YYYYMMDDTHHMMSS.qcow2`, where the
timestamp is the moment the snapshot was taken. `make snapshot DIR=/pool/keep`
writes it elsewhere, and `SNAPSHOT_DIR` in `config.env` changes the default.

Two properties of the file are deliberate:

- It is flattened with `qemu-img convert`, so it holds no reference to the base
  image and can be moved to another host on its own.
- It is taken with the guest shut down. Copying the disk of a running guest
  captures the state of a machine that was never shut down cleanly, which can
  mean a corrupt filesystem inside the copy. So the script stops the VM, copies
  the disk, and starts the VM again if it had been running. `--keep-off` leaves
  it stopped.

To go back:

```
make restore SNAPSHOT=snapshots/virtual-sandbox-20260922T143005.qcow2
make start
```

## Configuration

`config.env` holds every setting: VM name, sizing, image URL, libvirt URI,
pool, network and SSH keys. The scripts export those values to Terraform as
`TF_VAR_*`, so there is no `terraform.tfvars` to keep in step.

The package list installed by Ansible is in `ansible/group_vars/all.yml`. Add
what the current experiment needs and re-run `make provision`; the playbook is
idempotent.

## Layout

```
ubuntu-vm/
    README.md
    Makefile              # automation; wraps the scripts, adds nothing of its own
    config.env            # every setting, and the only file normally edited
    terraform/            # VM definition
        main.tf
        variables.tf
        outputs.tf
        cloud-init/       # first-boot user data and network configuration
    ansible/              # post-creation configuration
        site.yml
        group_vars/all.yml
        ansible.cfg
    scripts/              # lifecycle, snapshot, restore, inventory
    notes/                # notes about this project
```
