# Homelab: OpenTofu infrastructure

This document describes all infrastructure created on top of incus using OpenTofu.

## TODO List

1. create the infra for headscale and headplane
1. create the infra for Coolify
1. Via Coolify: install a password manager

## Configuration files

* `src/opentofu/providers.tf` — declares the `lxc/incus` provider, targeting the `homelab` remote already trusted via the laptop's Incus client config (`references/INSTALL.md`). No separate provider-side login needed.
* `src/opentofu/variables.tf` — `ssh_user` / `ssh_public_key` variables, filled in via `terraform.tfvars` (gitignored; copy `terraform.tfvars.example` and fill in the real values).
* `src/opentofu/naspool.tf` — the `naspool` LXC instance (`images:debian/12`), autostarted (`boot.autostart = true`), with the host's `/naspool` bind-mounted to `/naspool` via a `disk` device, and cloud-init provisioning that creates `var.ssh_user` with passwordless sudo and `var.ssh_public_key` as an authorized key (password auth disabled) — so Ansible can reach it, same as the homelab host itself.
  * This supersedes the `src/incus-compose/naspool.yaml` approach: incus-compose refuses bind mounts over a remote (HTTPS) connection as a client-side safety check ("not on the same host"), since bind-mount source paths are only meaningful read from the host actually running the Incus daemon. OpenTofu's `lxc/incus` provider has no such client-side guard — a `disk` device's `source` is resolved by the Incus daemon on the homelab regardless of which machine issues the API call, so it works fine from the laptop over HTTPS. See `references/INCUS-COMPOSE.md` for that background.
* Run with (from `src/opentofu/`): `tofu init`, `tofu plan`, `tofu apply`. See `references/INSTALL.md` for one-time laptop setup (installing `tofu` itself).
* After creating the instance, find its IP with `incus list`, then add it as a new Ansible host (`src/ansible/hosts`) to manage it going forward.