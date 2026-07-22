# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Project: Homelab

This project gathers all actions taken to setup a homelab.

The homelab is a NUC PC in the local network with minimal Debian installation. It's aimed to host Incus virtualization platform and Headscale for VPN.

The homelab has a static local IP (referred to as `<homelab-ip>` in docs; the real value is only in local config, not committed) and has a name 'homelab'.

## Repository state

This repo is in an early, mostly-documentation stage:

* `references/INSTALL.md` — manual setup steps already completed on the physical server (Debian install, static IP/DNS, SSH trust, Ansible install on the Windows laptop via WSL/Ubuntu, WSL-side incus CLI, router IPv6, and the headscale router firewall/DuckDNS steps). Treat this as a historical log of what was done manually, not a script to re-run.
* `references/ANSIBLE.md` — describes what's configured via Ansible. BTRFS disks mounted as DATA (`naspool.yml`), Incus installed and initialized including the `incusbr0` bridge and the storage buckets (S3) API (`incus.yml`), headscale + Caddy + headplane installed (`headscale.yml`, `headplane.yml`, connected via `incus exec` rather than SSH), the homelab host itself enrolled on its own tailnet (`tailscale.yml`) so host-only services like the Incus web UI are reachable over the VPN, Samba installed on the `naspool-samba` instance (`samba.yml`, also connected via `incus exec`) exporting `/naspool` over both the LAN and the tailnet, and a dedicated BTRFS subvolume prepared for Incus S3 storage buckets (`naspool-buckets.yml`, preceded by a safety snapshot of `/naspool`). NFS was tried too but dropped — the kernel NFS server can't run inside naspool-samba's unprivileged container.
* `references/INCUS-COMPOSE.md` — TODO list of infrastructure intended to be provisioned via `incus-compose`. Note: bind mounts (like the host's `/naspool`) don't work via incus-compose from the laptop — see `references/OPENTOFU.md`. Samba and S3 both ended up provisioned via OpenTofu + Ansible instead, for the same reason (and S3 has no container at all — it's served natively by Incus itself).
* `references/OPENTOFU.md` — describes what's configured via OpenTofu. `headscale` (LXC container fronted by Caddy + Let's Encrypt, running the headscale tailnet controller with embedded DERP, plus headplane as its web UI) is done. `naspool-samba` (LXC container with `/naspool` bind-mounted, connected via `incus exec` like `headscale` — no SSH/cloud-init; named `naspool-samba` rather than `naspool` to disambiguate it from the host's `/naspool` mount and the `naspool-buckets` storage pool) is done, exposing Samba (445/tcp) via a `proxy` device reachable from both the LAN and the tailnet. `naspool-buckets` (a BTRFS-backed Incus storage pool on a dedicated `/naspool/incus-buckets` subvolume, an `incus-bucket` storage bucket on it, and an admin-role bucket key) is done, tested end-to-end over S3. Coolify and a password manager are still TODO.
* `references/ARCHITECTURE.html` — a self-contained, hand-drawn-style network topology diagram of the current architecture (control plane, router/internet, homelab/Incus). Open directly in a browser to view. Regenerate/redraw by hand when the topology changes meaningfully — it's a snapshot, not generated from the other config.
* `src/ansible/` — inventory (`hosts`), `requirements.yml` (the `ansible.posix` and `community.general` collections), `group_vars/all/` (committed defaults plus a gitignored `01-local.yml` for per-host secrets like disk-by-id paths), and `playbooks/`:
  * `naspool.yml` — mounts the existing BTRFS RAID1 "naspool" volume at `/naspool`.
  * `naspool-buckets.yml` — takes a safety snapshot of `/naspool`, then creates a dedicated, empty BTRFS subvolume at `/naspool/incus-buckets` for the `naspool-buckets` Incus storage pool (see `naspool-buckets.tf`) — touches none of `/naspool`'s existing data.
  * `incus.yml` — installs Incus (+ web UI) from the Zabbly apt repo, initializes it (BTRFS-backed storage pool, `incusbr0` bridge, HTTPS API), activates the storage buckets (S3) API, and adds Docker/GHCR/GitLab OCI remotes.
  * `headscale.yml` — installs Caddy (Let's Encrypt) and headscale (pinned `.deb`, embedded DERP) on the `headscale` Incus instance. Connects via the `community.general.incus` connection plugin (`incus exec`, as root) instead of SSH, since that container has no SSH server or cloud-init.
  * `headplane.yml` — builds and installs headplane (headscale's web UI, no prebuilt binary exists upstream) from source into the **same** `headscale` instance, reachable at `/admin` via Caddy. Runs as its own unprivileged system user; talks to headscale's loopback API and reads/writes its `config.yaml` directly (co-located, since cross-host access is unsupported upstream).
  * `tailscale.yml` — targets the homelab host itself (`[myhosts]`, over SSH), not the `headscale` container. Installs the Tailscale client and registers it against our own headscale controller via a delegated preauth-key generation task, so services bound only to the host's own interfaces (the Incus HTTPS API/web UI) become reachable over the tailnet without any router/firewall changes.
  * `samba.yml` — targets the `naspool-samba` Incus instance (`[naspool_hosts]`), connected via `incus exec` like `headscale`, not SSH. Installs Samba, creates a Linux user per `samba_users` entry, and exports `/naspool` as a single read-write share reachable from both the LAN and the tailnet via `naspool.tf`'s `proxy` device. NFS was tried too but dropped — the kernel NFS server can't mount `/proc/fs/nfsd` inside an unprivileged Incus container.
* `src/incus-compose/` — incus-compose yml files used in this project. `naspool.yaml` is superseded by OpenTofu (see above) but kept for reference.
* `src/opentofu/` — `providers.tf` (the `lxc/incus` provider, targeting the `homelab` remote), `variables.tf` (`ssh_user`/`ssh_public_key`, filled via gitignored `terraform.tfvars`, still used by other resources but no longer by `naspool.tf`), `naspool.tf` (the `naspool-samba` LXC instance, `/naspool` bind-mounted, connected via `incus exec` rather than SSH/cloud-init — same as `headscale.tf` — with a `proxy` device exposing Samba on the LAN and tailnet), `naspool-buckets.tf` (a BTRFS-backed `naspool-buckets` Incus storage pool on the dedicated `/naspool/incus-buckets` subvolume prepared by `naspool-buckets.yml`, an `incus-bucket` storage bucket on it, and an admin-role `incus_storage_bucket_key` imported from Incus's own auto-created key), and `headscale.tf` (the `headscale` LXC instance on the default NAT'd `incusbr0` bridge, exposed via Incus `proxy` devices forwarding the homelab host's own ports — **not** a macvlan NIC, which doesn't work reliably over WiFi). Headplane needed no separate `.tf` — it rides inside `headscale.tf`'s existing container and ports.
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
