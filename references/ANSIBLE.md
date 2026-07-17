# Homelab: Ansible configurations

This document describes what is configured in the homelab using Ansible.


## TODO list

1. ~~Configure BTRFS disks as DATA~~ — done, see `src/ansible/playbooks/naspool.yml`
2. ~~Install incus~~ — done, see `src/ansible/playbooks/incus.yml`

## Playbooks

* `src/ansible/playbooks/naspool.yml` — mounts the existing BTRFS RAID1 "naspool" volume (two disks, already containing data, already configured as RAID1) at `/naspool`, persisted in `/etc/fstab` via filesystem UUID. Does not format or modify the filesystem contents.
  * Before running, create `src/ansible/group_vars/all/01-local.yml` (gitignored) with the real `naspool_disks` by-id paths, overriding the `CHANGEME` placeholders in `src/ansible/group_vars/all/00-defaults.yml` (find the real values on the homelab with `ls -l /dev/disk/by-id/ | grep -v part`).
  * Requires the `ansible.posix` collection: `ansible-galaxy collection install -r src/ansible/requirements.yml`.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/naspool.yml -K` (the `-K` flag prompts for luis's sudo password on the homelab, since the tasks require `become: true`)

* `src/ansible/playbooks/incus.yml` — adds the [Zabbly](https://github.com/zabbly/incus) Incus stable apt repository (Debian's own repo has no separate UI package), then installs `incus`, `incus-client`, and `incus-ui-canonical` from it, adds `luis` to the `incus-admin` group, and — only the first time it runs on a host with no storage pools yet — initializes Incus non-interactively via `incus admin init --preseed` (template: `src/ansible/playbooks/templates/incus-preseed.yml.j2`):
  * Repo setup (template: `src/ansible/playbooks/templates/zabbly-incus-stable.sources.j2`): downloads Zabbly's signing key to `/etc/apt/keyrings/zabbly.asc` and writes a deb822 `.sources` file targeting `https://pkgs.zabbly.com/incus/stable`, using the host's actual codename (`trixie`) and architecture.
  * Storage: a `btrfs`-driver "default" pool backed by a dedicated BTRFS subvolume at `/var/lib/incus` on the system disk (not on naspool), giving Incus native copy-on-write snapshots for instances/volumes instead of full-directory copies. Installing the package auto-starts `incusd`, which populates `/var/lib/incus` with pre-init state (server cert, empty database) before the subvolume is created; since nothing has been trusted or initialized at that point (guarded by the same "no storage pools yet" check), the playbook discards that state outright — stops `incus.socket`/`incus.service`, deletes `/var/lib/incus`, creates the subvolume, and restarts the service to let it generate fresh state directly inside it — rather than trying to preserve it.
  * Network: a NAT'd `incusbr0` bridge with an auto-assigned IPv4 range.
  * API/web UI: HTTPS listener bound to `0.0.0.0:8443` (configurable via `incus_https_address` in `group_vars/all/00-defaults.yml`), reachable at `https://<homelab-ip>:8443`. Set during first-time preseed init, and also enforced idempotently on every run via `incus config set core.https_address` (so the API gets activated even on a host that was initialized before this task existed, or if the address ever drifts).
  * Remotes: adds OCI remotes so images can be launched directly as Incus instances — `docker` (`https://docker.io`), `ghcr` (`https://ghcr.io`, GitHub Container Registry), and `gitlab` (`https://registry.gitlab.com`, GitLab Container Registry). Added under `luis`'s own client config (via `become_user`), not root's, since `luis` is the one using the `incus` CLI day-to-day.
  * Trust token: only if a trust entry named `{{ ansible_user }}-client` doesn't already exist (checked by name, not just "is the trust list empty" — the web UI adds its own `incus-ui.crt` entry on first browser login, which would otherwise make the list non-empty and skip this step), generates a one-time trust token (`incus config trust add "{{ ansible_user }}-client"`) and prints it via `debug`. Copy it from the Ansible output and use it with `incus remote add` from the laptop's `incus` CLI — see `references/INSTALL.md`. Re-running the playbook after that entry exists does not generate a new token.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/incus.yml -K`
  * After running, `luis`'s group membership only takes effect on a new SSH session (log out/in, or `newgrp incus-admin`).

