# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Project: Homelab

This project gathers all actions taken to setup a homelab.

The homelab is a NUC PC in the local network with minimal Debian installation. It's aimed to host Incus virtualization platform and Headscale for VPN.

The homelab has a static local IP (referred to as `<homelab-ip>` in docs; the real value is only in local config, not committed) and has a name 'homelab'.

## Repository state

This repo is in an early, mostly-documentation stage:

* `references/INSTALL.md` — manual setup steps already completed on the physical server (Debian install, static IP/DNS, SSH trust, Ansible install on the Windows laptop via WSL/Ubuntu). Treat this as a historical log of what was done manually, not a script to re-run.
* `references/ANSIBLE.md` — describes what's configured via Ansible. Both TODO items are done: BTRFS disks mounted as DATA (`naspool.yml`), Incus installed and initialized (`incus.yml`).
* `references/INCUS-COMPOSE.md` — TODO list of infrastructure intended to be provisioned via `incus-compose`. Note: bind mounts (like the host's `/naspool`) don't work via incus-compose from the laptop — see `references/OPENTOFU.md`.
* `references/OPENTOFU.md` — describes what's configured via OpenTofu. `naspool` (LXC container with `/naspool` bind-mounted, SSH access for Ansible) is done; headscale/headplane, Coolify, and a password manager are still TODO.
* `src/ansible/` — inventory (`hosts`), `requirements.yml` (the `ansible.posix` collection), `group_vars/all/` (committed defaults plus a gitignored `01-local.yml` for per-host secrets like disk-by-id paths), and `playbooks/`:
  * `naspool.yml` — mounts the existing BTRFS RAID1 "naspool" volume at `/naspool`.
  * `incus.yml` — installs Incus (+ web UI) from the Zabbly apt repo, initializes it (BTRFS-backed storage pool, `incusbr0` bridge, HTTPS API), and adds Docker/GHCR/GitLab OCI remotes.
* `src/incus-compose/` — incus-compose yml files used in this project. `naspool.yaml` is superseded by OpenTofu (see above) but kept for reference.
* `src/opentofu/` — `providers.tf` (the `lxc/incus` provider, targeting the `homelab` remote), `variables.tf` (`ssh_user`/`ssh_public_key`, filled via gitignored `terraform.tfvars`), and `naspool.tf` (the `naspool` LXC instance).
* `scripts/`, `assets/` — empty, reserved for future use.

## Working conventions

* When adding Ansible playbooks/roles, put them under `src/ansible/` alongside the existing `hosts` inventory, and update `references/ANSIBLE.md`'s TODO list to reflect what's been automated.
* When adding OpenTofu configuration, put it under `src/opentofu/`, and update `references/OPENTOFU.md`'s TODO list accordingly.
* Manual, one-off physical/BIOS/router-level steps (things Ansible/OpenTofu can't reach) belong in `references/INSTALL.md`, following its existing numbered-steps-with-shell-snippets style.
* The homelab user is `luis`; SSH from the Windows laptop works passwordless via a trusted key (see INSTALL.md). Ansible itself runs from WSL/Ubuntu on the laptop, not from native Windows.

## Verifying Ansible connectivity

From WSL/Ubuntu, from the directory containing the `hosts` file (`src/ansible/`):

```bash
ansible myhosts -i hosts -m ping
```

A successful run returns `"ping": "pong"` for the `homelab` host.
