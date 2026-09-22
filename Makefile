# Automation for the sandbox VM. Every target is a thin wrapper around a script
# in scripts/, so nothing here is only reachable through make.
#
# The VM name comes from config.env, and when that is empty it comes from the
# name of this directory. Nothing in this file hardcodes it, which is what lets
# a copy of this directory be an independent sandbox.

SHELL := /bin/bash
.DEFAULT_GOAL := help

VM := ./scripts/vm.sh
ANSIBLE_DIR := ansible
HOMELAB := homelab

# Everything a copy must not inherit: Terraform state and its marker point at
# the original VM, the inventory holds the original's address, and snapshots
# are large disk images that belong to the original.
COPY_EXCLUDES := --exclude ./.vm-name \
                 --exclude ./terraform/.terraform \
                 --exclude ./terraform/terraform.tfstate \
                 --exclude ./terraform/terraform.tfstate.backup \
                 --exclude ./ansible/inventory.ini \
                 --exclude ./snapshots

.PHONY: help name up provision all ssh ip status start stop restart down \
        snapshot restore inventory clone sync fmt validate clean-state

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-13s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  This directory is the sandbox called: $$($(VM) name)"

name: ## Print the VM name this directory resolves to
	@$(VM) name

up: ## Create the VM and wait until it answers over SSH
	@$(VM) up

provision: inventory ## Configure the VM with Ansible
	@cd $(ANSIBLE_DIR) && ansible-playbook site.yml

all: up provision ## Create the VM, then configure it

ssh: ## Open a shell in the VM
	@$(VM) ssh

ip: ## Print the VM's address
	@$(VM) ip

status: ## Show name, state, size and address
	@$(VM) status

start: ## Power on a stopped VM
	@$(VM) start

stop: ## Shut the guest down cleanly
	@$(VM) stop

restart: ## Stop, then start
	@$(VM) restart

down: ## Destroy the VM and its volumes
	@$(VM) down

inventory: ## Regenerate ansible/inventory.ini from the current address
	@./scripts/inventory.sh

snapshot: ## Snapshot the disk. DIR=<path> overrides the destination
	@./scripts/snapshot.sh $(DIR)

restore: ## Restore a snapshot. Requires SNAPSHOT=<file>
	@test -n "$(SNAPSHOT)" || { echo "usage: make restore SNAPSHOT=snapshots/<file>.qcow2" >&2; exit 2; }
	@./scripts/restore.sh "$(SNAPSHOT)"

clone: ## Copy this directory into a new sandbox. Requires NAME=<name>
	@test -n "$(NAME)" || { echo "usage: make clone NAME=my-other-sandbox" >&2; exit 2; }
	@test ! -e ../$(NAME) || { echo "../$(NAME) already exists" >&2; exit 2; }
	@mkdir -p ../$(NAME)
	@tar -cf - $(COPY_EXCLUDES) . | tar -xf - -C ../$(NAME)
	@echo "created ../$(NAME). It is a separate VM called '$(NAME)'; run 'make up' there."

sync: ## Copy this directory to homelab, under ~/projects/
	@tar -cf - $(COPY_EXCLUDES) . \
		| ssh $(HOMELAB) "mkdir -p projects/$$(basename $$PWD) && tar -xf - -C projects/$$(basename $$PWD)"
	@echo "synced to $(HOMELAB):projects/$$(basename $$PWD)/"

fmt: ## Format the Terraform files
	@terraform -chdir=terraform fmt

validate: ## Check the Terraform configuration
	@terraform -chdir=terraform init -backend=false -input=false >/dev/null
	@terraform -chdir=terraform validate

clean-state: ## Drop the local Terraform state. Touches no VM
	@rm -rf terraform/.terraform terraform/terraform.tfstate terraform/terraform.tfstate.backup .vm-name ansible/inventory.ini
	@echo "local state removed. No VM was changed."
