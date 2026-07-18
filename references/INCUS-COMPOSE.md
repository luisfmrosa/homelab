# Homelab: incus-compose infrastructure

This page describes the TODO list of infrastructure defined with incus-compose.

Incus-compose YML files used in this project are saved on `src/incus-compose/` directory.

## TODO List

1. create the container for Samba
1. create the container for S3

## Compose files

* `src/incus-compose/naspool.yaml` — **superseded by `src/opentofu/naspool.tf`, not currently usable.** Was a Debian 12 LXC system container (`images:debian/12`) with the host's `/naspool` bind-mounted in, but incus-compose refuses bind mounts over a remote (HTTPS) connection as a client-side same-host safety check, and this repo doesn't run incus-compose locally on the homelab (only from the laptop, over the `homelab` remote). Kept for reference in case incus-compose ends up installed directly on the homelab later — see `references/OPENTOFU.md` for the working equivalent.

