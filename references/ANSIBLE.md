# Homelab: Ansible configurations

This document describes what is configured in the homelab using Ansible.


## TODO list

1. ~~Configure BTRFS disks as DATA~~ — done, see `src/ansible/playbooks/naspool.yml`
2. ~~Install incus~~ — done, see `src/ansible/playbooks/incus.yml`
3. ~~Install and configure headscale (Caddy + Let's Encrypt + embedded DERP)~~ — done, see `src/ansible/playbooks/headscale.yml`.
4. ~~Install and configure headplane (the web UI)~~ — done, see `src/ansible/playbooks/headplane.yml`.
5. ~~Enrol the homelab host itself on the tailnet (so the Incus web UI is reachable over the VPN)~~ — done, see `src/ansible/playbooks/tailscale.yml`.

## Playbooks

* `src/ansible/playbooks/naspool.yml` — mounts the existing BTRFS RAID1 "naspool" volume (two disks, already containing data, already configured as RAID1) at `/naspool`, persisted in `/etc/fstab` via filesystem UUID. Does not format or modify the filesystem contents.
  * Before running, create `src/ansible/group_vars/all/01-local.yml` (gitignored) with the real `naspool_disks` by-id paths, overriding the `CHANGEME` placeholders in `src/ansible/group_vars/all/00-defaults.yml` (find the real values on the homelab with `ls -l /dev/disk/by-id/ | grep -v part`).
  * Requires the `ansible.posix` collection: `ansible-galaxy collection install -r src/ansible/requirements.yml`.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/naspool.yml -K` (the `-K` flag prompts for luis's sudo password on the homelab, since the tasks require `become: true`)

* `src/ansible/playbooks/incus.yml` — adds the [Zabbly](https://github.com/zabbly/incus) Incus stable apt repository (Debian's own repo has no separate UI package), then installs `incus`, `incus-client`, and `incus-ui-canonical` from it, adds `luis` to the `incus-admin` group, and — only the first time it runs on a host with no storage pools yet — initializes Incus non-interactively via `incus admin init --preseed` (template: `src/ansible/playbooks/templates/incus-preseed.yml.j2`):
  * Repo setup (template: `src/ansible/playbooks/templates/zabbly-incus-stable.sources.j2`): downloads Zabbly's signing key to `/etc/apt/keyrings/zabbly.asc` and writes a deb822 `.sources` file targeting `https://pkgs.zabbly.com/incus/stable`, using the host's actual codename (`trixie`) and architecture.
  * Storage: a `btrfs`-driver "default" pool backed by a dedicated BTRFS subvolume at `/var/lib/incus-pool` on the system disk (not on naspool), giving Incus native copy-on-write snapshots for instances/volumes instead of full-directory copies. The pool's `source` must be a location entirely separate from `/var/lib/incus` — even nesting it *under* `/var/lib/incus` as its own subvolume (e.g. `/var/lib/incus/storage-pools/default`) is wrong: Incus ends up bind-mounting that subvolume a second time inside itself, aliasing the daemon's own database/certs/sockets into the pool path (confirmed in practice via `mount | grep storage-pools/default` showing the same `subvol=` as `/var/lib/incus`'s own mount). The playbook creates the `/var/lib/incus-pool` subvolume before first-time init (guarded by the same "no storage pools yet" check) if it doesn't already exist, and preseed init (`incus-preseed.yml.j2`) points the pool's `source` at it.
  * Network: a NAT'd `incusbr0` bridge (auto-assigned IPv4 and IPv6 ranges), added to the default profile's `eth0` device so instances using the default profile get network connectivity automatically. Guarded independently of the storage-pool/preseed check above (checks `incus network list` / `incus profile show default` directly) — the preseed-bundled version of this only runs once ever, so a host that already had a storage pool from an earlier partial run (as happened in practice on this homelab) would otherwise be stuck with no bridge forever.
  * API/web UI: HTTPS listener bound to `0.0.0.0:8443` (configurable via `incus_https_address` in `group_vars/all/00-defaults.yml`), reachable at `https://<homelab-ip>:8443`. Set during first-time preseed init, and also enforced idempotently on every run via `incus config set core.https_address` (so the API gets activated even on a host that was initialized before this task existed, or if the address ever drifts).
  * Remotes: adds OCI remotes so images can be launched directly as Incus instances — `docker` (`https://docker.io`), `ghcr` (`https://ghcr.io`, GitHub Container Registry), and `gitlab` (`https://registry.gitlab.com`, GitLab Container Registry). Added under `luis`'s own client config (via `become_user`), not root's, since `luis` is the one using the `incus` CLI day-to-day.
  * Trust token: only if a trust entry named `{{ ansible_user }}-client` doesn't already exist (checked by name, not just "is the trust list empty" — the web UI adds its own `incus-ui.crt` entry on first browser login, which would otherwise make the list non-empty and skip this step), generates a one-time trust token (`incus config trust add "{{ ansible_user }}-client"`) and prints it via `debug`. Copy it from the Ansible output and use it with `incus remote add` from the laptop's `incus` CLI — see `references/INSTALL.md`. Re-running the playbook after that entry exists does not generate a new token.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/incus.yml -K`
  * After running, `luis`'s group membership only takes effect on a new SSH session (log out/in, or `newgrp incus-admin`).

* `src/ansible/playbooks/headscale.yml` — targets the `[headscale_hosts]` inventory group (the `headscale` Incus instance created by `src/opentofu/headscale.tf`, on the default NAT'd `incusbr0` bridge — see `references/OPENTOFU.md` for why a macvlan NIC on the homelab's WiFi was tried and abandoned). Connects via the `community.general.incus` connection plugin (`incus exec` against the trusted `homelab` remote, as root) instead of SSH — the container has no SSH server and no non-root user; the base `images:debian/12` image has no cloud-init either, so nothing is pre-provisioned. Requires a working `incus` CLI trusted against the `homelab` remote from inside WSL/Ubuntu itself (separate from the Windows-side one used by `incus`/`incus-compose`/OpenTofu) — see `references/INSTALL.md`. The image also ships with **no Python interpreter**, which Ansible's non-`raw`/`command` modules need — after `tofu apply` creates (or recreates) the instance, bootstrap it once with `incus exec headscale -- apt-get update && incus exec headscale -- apt-get install -y python3` before running this playbook, or the `Gathering Facts` step fails with "No python interpreters found". Installs Caddy from its own apt repo and headscale from a pinned `.deb` release (no apt repo exists for headscale), then configures:
  * Caddy (template: `src/ansible/playbooks/templates/Caddyfile.j2`) as a reverse proxy in front of headscale's plain-HTTP listener, for the site `headscale_domain` (`group_vars/all/00-defaults.yml`, currently `<headscale-domain>`) — Caddy obtains and renews its Let's Encrypt certificate automatically, no separate certbot setup needed.
  * headscale (template: `src/ansible/playbooks/templates/headscale-config.yaml.j2`) with its embedded DERP relay enabled (no separate `derper` binary/service), STUN listening on `headscale_derp_stun_port` (default `3478/udp`, must be forwarded on the router — see `references/INSTALL.md`).
  * `headscale_version` (`group_vars/all/00-defaults.yml`) pins the installed release — bump it and re-run the playbook to upgrade, but see "Upgrading headscale" below before jumping to a new version.
  * Users: creates any usernames listed in `headscale_users` (`group_vars/all/00-defaults.yml`, defaults to `[]`) via `headscale users create`, checked against `headscale users list -o json` first so re-running is idempotent. Override the list in the gitignored `group_vars/all/01-local.yml` — kept out of git since it's personal account data, not infrastructure. Node registration itself stays manual (see `references/INSTALL.md`), since it requires an interactive nodekey/pre-auth key from the client at enrollment time.
  * Requires the `community.general` collection (`ansible-galaxy collection install -r src/ansible/requirements.yml`).
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headscale.yml` (no `-K` needed — connects as root via `incus exec`, not sudo-over-SSH).
  * Manual, one-off steps this playbook cannot reach (router firewall rules, DuckDNS domain) are documented in the "headscale" section of `references/INSTALL.md`.

* `src/ansible/playbooks/headplane.yml` — installs [headplane](https://github.com/tale/headplane) (headscale's web UI) into the **same** `headscale` Incus instance, co-located rather than in a separate container, since full DNS/network-management editing requires headplane to read headscale's actual `config.yaml` from the local filesystem (cross-host access is explicitly documented upstream as "advanced, unsupported"). Depends on `headscale.yml` having already run (needs the headscale service, API, and config file to exist first). There's no prebuilt binary/tarball release upstream (only Docker images or source), and this container intentionally has no Docker, so headplane is **built from source**:
  * Node.js (`headplane_node_major` in `group_vars/all/00-defaults.yml`, currently `24`) is installed from the [NodeSource](https://github.com/nodesource/distributions) apt repository — Debian 12's own repo only ships Node 18, too old for headplane. Uses the same `deb822_repository` idiom as Caddy's own repo setup in `headscale.yml`. `corepack enable` then provides `pnpm`.
  * A dedicated unprivileged `headplane` system user/group runs the service (distinct from headscale's own system user).
  * Headplane's source is cloned at the pinned tag (`headplane_version`, currently `0.7.0`) to `headplane_install_dir` (`/opt/headplane`), then built with `pnpm install --frozen-lockfile && pnpm run build` — only re-run when the checked-out tag doesn't match, same "check installed version string, only act if it doesn't match" idiom already used for headscale's own `.deb` install.
  * Two secrets are generated once and persisted only on the container's filesystem — **never** written to `group_vars` or git, unlike user-supplied vars such as `naspool_disks`/`headscale_users`: a cookie-signing secret (`/etc/headplane/cookie_secret`, `openssl rand -base64 32`) and a long-lived headscale API key (`/etc/headplane/api_key`, `headscale apikeys create --expiration 8760h`, ~1 year). Both are guarded by a file-exists check (same idiom as `incus.yml`'s trust-token task) so re-running the playbook doesn't regenerate them and invalidate existing sessions/break the configured key.
  * `/etc/headscale/config.yaml` (deployed `root:root 0644` by `headscale.yml`) has its group changed to `headplane` and mode set to `0664`, so headplane — running as its own unprivileged user — can write it back when DNS/network settings are edited from the UI.
  * Headplane's own config (template: `src/ansible/playbooks/templates/headplane-config.yaml.j2`) points `headscale.url` at `http://127.0.0.1:8080` (headscale's own loopback API) and `headscale.config_path` at `/etc/headscale/config.yaml`; `integration.proc.enabled: true` is required for the DNS/network-management editing UI to work (it's how headplane finds and signals the running headscale process) — `agent`/`docker`/`kubernetes` integrations all stay disabled (no SSH-in-browser, no Docker, no k8s).
  * Runs via a generated systemd unit (template: `src/ansible/playbooks/templates/headplane.service.j2`) on port `headplane_port` (currently `3000`, loopback only), with `After=`/`Requires=headscale.service`.
  * The shared Caddyfile (template: `src/ansible/playbooks/templates/Caddyfile.j2`, also deployed by this playbook) routes `/admin/*` to headplane and everything else to headscale's own API, on the same domain/certificate — no new DNS/firewall changes needed.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headplane.yml` (after `headscale.yml`). Reachable at `https://<headscale_domain>/admin`; log in using the value in `/etc/headplane/api_key` (`incus exec headscale -- cat /etc/headplane/api_key`).

* `src/ansible/playbooks/tailscale.yml` — targets `[myhosts]` (the homelab host itself, over SSH, `become: true`), not the `headscale` container. Enrols the homelab host as a tailnet node so that services bound only to the host's own interfaces — chiefly the Incus HTTPS API/web UI (`incus_https_address`, currently `0.0.0.0:8443`, see `incus.yml`) — become reachable from any other device on the tailnet, without opening anything new on the router or changing `incus_https_address` itself (LAN reachability is kept, not replaced).
  * Installs the official Tailscale client from its own apt repo (signing key + deb822 `.sources` file, same idiom as Caddy's and Incus's repo setup in `headscale.yml`/`incus.yml`), keyed off `ansible_distribution_release` so it tracks whatever Debian codename the host actually runs.
  * Registers the host non-interactively: generates a short-lived (10 minute) headscale preauth key for the `tailscale_headscale_user` user (`group_vars/all/00-defaults.yml`, currently `luis` — must be a name already listed in `headscale_users`) by delegating that one task to the `headscale` host (`delegate_to: headscale`, `become: false`, since that host connects as root via `incus exec` already), then runs `tailscale up --login-server=https://{{ headscale_domain }} --authkey=...` on the homelab host itself. Both steps are guarded by `tailscale status --json`'s `BackendState` so re-running the playbook is a no-op once already enrolled (a preauth key can only be used once, so this guard matters — re-running it against an already-enrolled host without the guard would waste a key generation call).
  * No exit-node flags are set (`--advertise-exit-node`, `--exit-node`) — this tailnet doesn't route general client (e.g. phone) traffic through the homelab; nodes just need normal outbound internet access for their own updates, which they already have.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/tailscale.yml -K` (needs `-K` for sudo on the homelab host itself, same as `incus.yml`/`naspool.yml`). Requires `headscale.yml` to have already run (needs a working headscale API and the `tailscale_headscale_user` to already exist as a headscale user).
  * After running, the Incus web UI is reachable at `https://<homelab-tailnet-ip>:8443` from any other tailnet-enrolled device — find the tailnet IP with `incus exec headscale -- headscale nodes list` or `tailscale ip` on the homelab host itself.

### Renewing the headplane API key

The API key headplane uses to talk to headscale expires after ~1 year (`--expiration 8760h`) and, per headscale's own behavior, can't be retrieved again once created — there's no automated rotation. To renew:

1. Generate a new key: `incus exec headscale -- headscale apikeys create --expiration 8760h`
2. Replace the file's contents on the container: `incus exec headscale -- sh -c 'echo "<new-key>" > /etc/headplane/api_key'`
3. Re-run `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headplane.yml` to redeploy headplane's config with the new key and restart the service (the generation task itself won't re-run, since it's guarded by the file already existing — only the redeploy/restart happens).

## Upgrading headscale

Headscale enforces a strict upgrade path: it refuses to start if the database was last touched by a binary more than one minor version behind, and pre-0.25.0 databases aren't supported by 0.28.0+'s migrations at all. **Always upgrade one minor version at a time** (latest stable patch of each — check https://github.com/juanfont/headscale/releases for what actually exists, some minors skip straight to a later patch or only have a release candidate), never straight to the newest release. Patch-only bumps within the same minor (e.g. `0.27.0` → `0.27.1`) don't need this — only crossing a minor-version boundary does.

For each hop:

1. **Snapshot the container** (the `incus` CLI already defaults to the `homelab` remote, so `--remote` is optional if you've run `incus remote switch homelab`):
   ```bash
   incus snapshot create headscale pre-<target-version>
   ```
2. **Bump `headscale_version`** in `src/ansible/group_vars/all/00-defaults.yml` to that target version.
3. **Run the playbook** (from WSL, since it uses the `community.general.incus` connection plugin):
   ```bash
   ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headscale.yml
   ```
4. **Verify** before moving to the next hop:
   ```bash
   incus exec headscale -- headscale version
   incus exec headscale -- headscale nodes list
   incus exec headscale -- systemctl status headscale --no-pager
   ```
   Confirm the version matches, both existing nodes are still listed, and the service is `active (running)` with no migration errors in the log tail.
5. **Roll back if a hop goes wrong:**
   ```bash
   incus exec headscale -- systemctl stop headscale
   incus restore headscale pre-<target-version>
   ```
6. Once confident in a hop, prune its snapshot: `incus snapshot delete headscale pre-<target-version>`.

Repeat for each intervening minor version until reaching the target release. Also check the target release's notes for a **minimum required Tailscale client version** — the Android/Windows/etc. apps enrolled as nodes may need updating too, or they'll fail to reconnect once the server's floor rises past their version.

