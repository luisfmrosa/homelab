# Homelab: incus-compose infrastructure

This page describes the TODO list of infrastructure defined with incus-compose.

Incus-compose YML files used in this project are saved on `src/incus-compose/` directory.

## TODO List

1. ~~create the container for Samba~~ — didn't end up going through incus-compose. Samba runs directly on the `naspool-samba` instance instead, provisioned by OpenTofu (`src/opentofu/naspool.tf`) and configured by Ansible (`src/ansible/playbooks/samba.yml`) — same tool-boundary reasoning as `naspool.yaml` below (bind mounts don't work via incus-compose from the laptop). NFS was tried too but dropped — see `samba.yml`'s own header comment and `naspool.tf` for why. See `references/OPENTOFU.md` and `references/ANSIBLE.md`.
1. ~~create the container for S3~~ — didn't end up going through incus-compose either. S3 is served natively by Incus itself (a storage bucket on a dedicated BTRFS storage pool), no container involved — provisioned by OpenTofu (`src/opentofu/naspool-buckets.tf`) with the underlying subvolume prepared by Ansible (`src/ansible/playbooks/naspool-buckets.yml`). See `references/OPENTOFU.md` and `references/ANSIBLE.md`.
1. ~~create the containers for Immich~~ — didn't go through incus-compose either, for a related but distinct reason: Immich's 4 services run as Incus OCI "application containers" (`incus launch docker:...`/`ghcr:...`), not docker-compose-managed containers at all — incus-compose orchestrates compose files, but there's no compose file involved here once each service is its own native Incus instance. Provisioned by OpenTofu (`src/opentofu/immich.tf`, the isolated project/network) and Ansible (`src/ansible/playbooks/immich.yml`, the 4 instances themselves). See `references/OPENTOFU.md` and `references/ANSIBLE.md`.

1. ~~create the containers for the media stack (Jellyfin, Navidrome, Kavita)~~ — didn't go through incus-compose either, same reason as Immich: all three are single Incus OCI "application containers" (`incus launch ghcr:...`/`docker:...`), with no compose file involved once each service is its own native Incus instance. Jellyfin additionally needs an Incus `gpu` device for QuickSync hardware transcoding, which is an Incus-native device type with no incus-compose equivalent. Provisioned by OpenTofu (`src/opentofu/media.tf`, the isolated project/network) and Ansible (`src/ansible/playbooks/media.yml`, the three instances themselves). See `references/OPENTOFU.md` and `references/ANSIBLE.md`.

## Compose files

* `src/incus-compose/naspool.yaml` — **superseded by `src/opentofu/naspool.tf`, not currently usable.** Was a Debian 12 LXC system container (`images:debian/12`) with the host's `/naspool` bind-mounted in, but incus-compose refuses bind mounts over a remote (HTTPS) connection as a client-side same-host safety check, and this repo doesn't run incus-compose locally on the homelab (only from the laptop, over the `homelab` remote). Kept for reference in case incus-compose ends up installed directly on the homelab later — see `references/OPENTOFU.md` for the working equivalent.

