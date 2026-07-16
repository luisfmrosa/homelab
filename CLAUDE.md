# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Project: Homelab

This project gathers all actions taken to setup a homelab.

The homelab is a NUC PC in the local network with minimal Debian installation. It's aimed to host Incus virtualization platform and Headscale for VPN.

The homelab has a static local IP (referred to as `<homelab-ip>` in docs; the real value is only in local config, not committed) and has a name 'homelab'.

## Repository state

This repo is in an early, mostly-documentation stage:

* `references/INSTALL.md` — manual setup steps already completed on the physical server (Debian install, static IP/DNS, SSH trust, Ansible install on the Windows laptop via WSL/Ubuntu). Treat this as a historical log of what was done manually, not a script to re-run.
* `references/ANSIBLE.md` — TODO list of configuration tasks intended to be automated via Ansible (not yet implemented). Currently: configure BTRFS disks as DATA, install Incus.
* `references/OPENTOFU.md` — TODO list of infrastructure intended to be provisioned via OpenTofu on top of Incus (not yet implemented). Currently: Headscale, Headplane, Coolify (integrated with Incus), export DATA as S3/Samba, a password manager via Coolify.
* `src/ansible/` — contains only the inventory file `hosts` so far (no playbooks yet):
  ```
  [myhosts]
  homelab ansible_user=luis
  ```
* `src/opentofu/` — empty, no OpenTofu configuration written yet.
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
