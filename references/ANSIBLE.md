# Homelab: Ansible configurations

This document describes what is configured in the homelab using Ansible.


## TODO list

1. ~~Configure BTRFS disks as DATA~~ — done, see `src/ansible/playbooks/naspool.yml`
2. ~~Install incus~~ — done, see `src/ansible/playbooks/incus.yml`
3. ~~Install and configure headscale (Caddy + Let's Encrypt + embedded DERP)~~ — done, see `src/ansible/playbooks/headscale.yml`.
4. ~~Install and configure headplane (the web UI)~~ — done, see `src/ansible/playbooks/headplane.yml`.
5. ~~Enrol the homelab host itself on the tailnet (so the Incus web UI is reachable over the VPN)~~ — done, see `src/ansible/playbooks/tailscale.yml`.
6. ~~Export naspool over Samba, reachable over LAN and tailnet~~ — done, see `src/ansible/playbooks/samba.yml`. NFS was attempted too but dropped — see the playbook's own header comment and `src/opentofu/naspool.tf` for why.
7. ~~Prepare naspool for S3 storage buckets~~ — done, see `src/ansible/playbooks/naspool-buckets.yml`.
8. ~~Deploy Immich~~ — done, see `src/ansible/playbooks/immich.yml`.
9. ~~Deploy the media stack (Jellyfin, Navidrome, Kavita)~~ — done, see `src/ansible/playbooks/media.yml`.
10. ~~Install Coolify and prepare a sandbox server for it~~ — done, see `src/ansible/playbooks/coolify.yml`.
11. ~~Deploy Wallos (subscription tracker)~~ — done, added to `src/ansible/playbooks/media.yml` rather than given its own playbook: it's a single OCI container in the already-existing `media` project, needing no new OpenTofu resources at all.

## Playbooks

* `src/ansible/playbooks/naspool.yml` — mounts the existing BTRFS RAID1 "naspool" volume (two disks, already containing data, already configured as RAID1) at `/naspool`, persisted in `/etc/fstab` via filesystem UUID. Does not format or modify the filesystem contents.
  * Before running, create `src/ansible/group_vars/all/01-local.yml` (gitignored) with the real `naspool_disks` by-id paths, overriding the `CHANGEME` placeholders in `src/ansible/group_vars/all/00-defaults.yml` (find the real values on the homelab with `ls -l /dev/disk/by-id/ | grep -v part`).
  * Requires the `ansible.posix` collection: `ansible-galaxy collection install -r src/ansible/requirements.yml`.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/naspool.yml -K` (the `-K` flag prompts for luis's sudo password on the homelab, since the tasks require `become: true`)

* `src/ansible/playbooks/naspool-buckets.yml` — targets `[myhosts]` (the homelab host itself, over SSH, `become: true`), same as `naspool.yml`. Prepares `/naspool` for use as the source of an Incus storage pool (see `src/opentofu/naspool-buckets.tf`), without touching any existing data:
  * Takes a one-time, read-only BTRFS snapshot of the whole `/naspool` subvolume at `/naspool/.snapshots/pre-incus-buckets` before creating anything — a cheap, near-instant rollback point, guarded by a file-exists check so it's never retaken on subsequent runs.
  * Creates a dedicated, empty BTRFS subvolume at `/naspool/incus-buckets` — mirrors the same "pool source must be its own dedicated subvolume, not the mount root" pattern already used for the `default` Incus pool at `/var/lib/incus-pool` (see `incus.yml` below). No `/etc/fstab` entry needed; a subvolume of an already-mounted BTRFS filesystem is reachable at its plain path with no separate mount.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/naspool-buckets.yml -K` (needs `-K` for sudo on the homelab host, same as `naspool.yml`/`incus.yml`).

* `src/ansible/playbooks/incus.yml` — adds the [Zabbly](https://github.com/zabbly/incus) Incus stable apt repository (Debian's own repo has no separate UI package), then installs `incus`, `incus-client`, and `incus-ui-canonical` from it, adds `luis` to the `incus-admin` group, and — only the first time it runs on a host with no storage pools yet — initializes Incus non-interactively via `incus admin init --preseed` (template: `src/ansible/playbooks/templates/incus-preseed.yml.j2`):
  * Repo setup (template: `src/ansible/playbooks/templates/zabbly-incus-stable.sources.j2`): downloads Zabbly's signing key to `/etc/apt/keyrings/zabbly.asc` and writes a deb822 `.sources` file targeting `https://pkgs.zabbly.com/incus/stable`, using the host's actual codename (`trixie`) and architecture.
  * Storage: a `btrfs`-driver "default" pool backed by a dedicated BTRFS subvolume at `/var/lib/incus-pool` on the system disk (not on naspool), giving Incus native copy-on-write snapshots for instances/volumes instead of full-directory copies. The pool's `source` must be a location entirely separate from `/var/lib/incus` — even nesting it *under* `/var/lib/incus` as its own subvolume (e.g. `/var/lib/incus/storage-pools/default`) is wrong: Incus ends up bind-mounting that subvolume a second time inside itself, aliasing the daemon's own database/certs/sockets into the pool path (confirmed in practice via `mount | grep storage-pools/default` showing the same `subvol=` as `/var/lib/incus`'s own mount). The playbook creates the `/var/lib/incus-pool` subvolume before first-time init (guarded by the same "no storage pools yet" check) if it doesn't already exist, and preseed init (`incus-preseed.yml.j2`) points the pool's `source` at it.
  * Network: a NAT'd `incusbr0` bridge (auto-assigned IPv4 and IPv6 ranges), added to the default profile's `eth0` device so instances using the default profile get network connectivity automatically. Guarded independently of the storage-pool/preseed check above (checks `incus network list` / `incus profile show default` directly) — the preseed-bundled version of this only runs once ever, so a host that already had a storage pool from an earlier partial run (as happened in practice on this homelab) would otherwise be stuck with no bridge forever.
  * API/web UI: HTTPS listener bound to `0.0.0.0:8443` (configurable via `incus_https_address` in `group_vars/all/00-defaults.yml`), reachable at `https://<homelab-ip>:8443`. Set during first-time preseed init, and also enforced idempotently on every run via `incus config set core.https_address` (so the API gets activated even on a host that was initialized before this task existed, or if the address ever drifts).
  * Storage buckets (S3) API: HTTPS listener bound to `0.0.0.0:8555` (configurable via `incus_storage_buckets_address` in `group_vars/all/00-defaults.yml`), enforced idempotently the same way as `core.https_address` above via `incus config set core.storage_buckets_address`. Gates whether *any* Incus storage pool can host S3 buckets at all — see `naspool-buckets.yml` and `src/opentofu/naspool-buckets.tf`.
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
  * Two secrets are generated once and persisted only on the container's filesystem — **never** written to `group_vars` or git, unlike user-supplied vars such as `naspool_disks`/`headscale_users`: a cookie-signing secret (`/etc/headplane/cookie_secret`, `openssl rand -hex 16`) and a long-lived headscale API key (`/etc/headplane/api_key`, `headscale apikeys create --expiration 8760h`, ~1 year). Both are guarded by a file-exists check (same idiom as `incus.yml`'s trust-token task) so re-running the playbook doesn't regenerate them and invalidate existing sessions/break the configured key.
  * `/etc/headscale/config.yaml` (deployed `root:root 0644` by `headscale.yml`) has its group changed to `headplane` and mode set to `0664`, so headplane — running as its own unprivileged user — can write it back when DNS/network settings are edited from the UI.
  * Headplane's own config (template: `src/ansible/playbooks/templates/headplane-config.yaml.j2`) points `headscale.url` at `http://127.0.0.1:8080` (headscale's own loopback API) and `headscale.config_path` at `/etc/headscale/config.yaml`; `integration.proc.enabled: true` is required for the DNS/network-management editing UI to work (it's how headplane finds and signals the running headscale process) — `agent`/`docker`/`kubernetes` integrations all stay disabled (no SSH-in-browser, no Docker, no k8s).
  * Runs via a generated systemd unit (template: `src/ansible/playbooks/templates/headplane.service.j2`) on port `headplane_port` (currently `3000`, loopback only), with `After=`/`Requires=headscale.service`.
  * The shared Caddyfile (template: `src/ansible/playbooks/templates/Caddyfile.j2`, also deployed by this playbook) routes `/admin/*` to headplane and everything else to headscale's own API, on the same domain/certificate — no new DNS/firewall changes needed. A `redir /admin /admin/ 301` sits above those two `handle` blocks: a bare `/admin` doesn't match `handle /admin/*`, so without it the request falls through to headscale's API and returns a bare 404 (verified). Note the template is rendered by three playbooks (`headscale.yml`, `headplane.yml`, `dashboard.yml`) — each writes the whole file, so it always contains every block regardless of which ran last.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headplane.yml` (after `headscale.yml`). Reachable at `https://<headscale_domain>/admin/` (a bare `/admin` is redirected there by Caddy, see above); log in using the value in `/etc/headplane/api_key` (`incus exec headscale -- cat /etc/headplane/api_key`).

* `src/ansible/playbooks/tailscale.yml` — targets `[myhosts]` (the homelab host itself, over SSH, `become: true`), not the `headscale` container. Enrols the homelab host as a tailnet node so that services bound only to the host's own interfaces — chiefly the Incus HTTPS API/web UI (`incus_https_address`, currently `0.0.0.0:8443`, see `incus.yml`) — become reachable from any other device on the tailnet, without opening anything new on the router or changing `incus_https_address` itself (LAN reachability is kept, not replaced).
  * Installs the official Tailscale client from its own apt repo (signing key + deb822 `.sources` file, same idiom as Caddy's and Incus's repo setup in `headscale.yml`/`incus.yml`), keyed off `ansible_distribution_release` so it tracks whatever Debian codename the host actually runs.
  * Registers the host non-interactively: generates a short-lived (10 minute) headscale preauth key for the `tailscale_headscale_user` user (`group_vars/all/00-defaults.yml`, currently `luis` — must be a name already listed in `headscale_users`) by delegating that one task to the `headscale` host (`delegate_to: headscale`, `become: false`, since that host connects as root via `incus exec` already), then runs `tailscale up --login-server=https://{{ headscale_domain }} --authkey=...` on the homelab host itself. Both steps are guarded by `tailscale status --json`'s `BackendState` so re-running the playbook is a no-op once already enrolled (a preauth key can only be used once, so this guard matters — re-running it against an already-enrolled host without the guard would waste a key generation call).
  * No exit-node flags are set (`--advertise-exit-node`, `--exit-node`) — this tailnet doesn't route general client (e.g. phone) traffic through the homelab; nodes just need normal outbound internet access for their own updates, which they already have.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/tailscale.yml -K` (needs `-K` for sudo on the homelab host itself, same as `incus.yml`/`naspool.yml`). Requires `headscale.yml` to have already run (needs a working headscale API and the `tailscale_headscale_user` to already exist as a headscale user).
  * After running, the Incus web UI is reachable at `https://<homelab-tailnet-ip>:8443` from any other tailnet-enrolled device — find the tailnet IP with `incus exec headscale -- headscale nodes list` or `tailscale ip` on the homelab host itself.

* `src/ansible/playbooks/samba.yml` — targets the `[naspool_hosts]` inventory group (the `naspool-samba` Incus instance created by `src/opentofu/naspool.tf` — named `naspool-samba` rather than `naspool` to disambiguate it from the host's `/naspool` BTRFS mount and the planned `naspool-buckets` storage pool). Connects via the `community.general.incus` connection plugin (`incus exec`, as root), same as `headscale.yml`/`headplane.yml` — this instance has no SSH server or cloud-init user either. The base `images:debian/12` image also ships with **no Python interpreter**, which Ansible's non-`raw`/`command` modules need — same issue as `headscale.yml` — so after `tofu apply` creates (or recreates) the instance, bootstrap it once with `incus exec naspool-samba -- apt-get update && incus exec naspool-samba -- apt-get install -y python3` before running this playbook, or the `Gathering Facts` step fails with "No python interpreters found". Installs `samba`, then:
  * Creates a Linux system user for each name in `samba_users` (`group_vars/all/00-defaults.yml`, defaults to `[]`) — this instance has no pre-provisioned user at all, so these accounts exist solely as Samba auth identities (no shell, no home directory).
  * Deploys `/etc/samba/smb.conf` (template: `src/ansible/playbooks/templates/smb.conf.j2`) with a single `[naspool]` share at `/naspool`, read-write, restricted to `valid users = {{ samba_users | join(' ') }}` — every listed user gets identical access, there's no per-user permission split.
  * Sets each user's Samba password via `smbpasswd -a -s`, once per user — guarded by a per-user marker file (`/etc/samba/.smbpasswd_set_<user>`), same file-exists idiom as headplane's generated secrets. Passwords come from a parallel `samba_passwords` map (keyed by username) in the gitignored `group_vars/all/01-local.yml` — kept out of git like `headscale_users`/`naspool_disks`, since it's personal account data. The task is `no_log: true` so passwords never appear in Ansible output.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/samba.yml` (no `-K` needed, same reasoning as `headscale.yml`).
  * Reachable at `smb://<homelab-lan-ip-or-tailnet-ip>/naspool`, both LAN and tailnet, via the same `proxy` device pattern used for the Incus web UI (see `tailscale.yml` above).
  * **NFS was tried and dropped**: the kernel NFS server (`nfs-kernel-server`) needs to mount `/proc/fs/nfsd`, which unprivileged Incus containers can't do (`mount: /proc/fs/nfsd: permission denied` in practice) — that's a deliberate host-kernel isolation boundary, not a missing package. Making `naspool` a privileged container would work around it, but meaningfully weakens container isolation for a share whose actual clients (phone, laptop) are all well served by Samba/SMB alone, so NFS was skipped rather than trading away that isolation.

* `src/ansible/playbooks/immich.yml` — targets `[myhosts]` (the homelab host itself, over SSH), not `community.general.incus`/`incus exec` like `headscale.yml`/`samba.yml` — these 4 instances don't exist yet at the start of a first run, so there's nothing for `incus exec` to target. Deploys Immich (self-hosted photo management) as 4 separate Incus OCI "application containers" (Incus 6.3+, `incus launch docker:...`/`ghcr:...`) inside the isolated `immich` Incus project created by `src/opentofu/immich.tf` — one instance per upstream `docker-compose.yml` service, rather than a single Docker-in-LXC container running a compose stack:
  * `immich-db` (`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, the VectorChord-bundled Postgres image Immich itself publishes), `immich-redis` (`docker.io/valkey/valkey:9`), `immich-ml` (`ghcr.io/immich-app/immich-machine-learning`), `immich-server` (`ghcr.io/immich-app/immich-server`) — using the `docker`/`ghcr` OCI remotes `incus.yml` already configures under `luis`'s own client config.
  * All `incus` tasks run as the plain SSH login user (`luis`, no `become`/sudo) — the OCI remotes above live in `luis`'s own Incus client config (`~/.config/incus/config.yml`), not root's; running these commands as root instead fails with `Error: The remote "ghcr" doesn't exist`, since Incus remotes are per-user client state, not daemon-side (confirmed in practice). `luis` is already in the `incus-admin` group (`incus.yml`), so no root is needed at all for talking to the Incus socket. Only the host directory-creation/chown tasks need actual root, via their own `become: true`.
  * Each instance needing a bind mount (`immich-db`, `immich-ml`, `immich-server`) is created stopped via `incus init` (env vars set inline via `-c environment.KEY=value` — those aren't override-only), given its disk device via a separate `incus config device add`, then started — `incus launch -d name,disk,...` only *overrides* a device that already exists on a profile, it can't add a brand-new one (confirmed: `Cannot override device ...: device not found in profiles`), and the `immich` project's own default profile has no such device.
  * Every device-add/start step is guarded by checking the **device's**/**instance's current state** directly (`incus config device list`, `incus list ... -f json`), not by whether the instance already existed when the play started — instance creation and its disk device attachment aren't atomic, and a transient failure between the two (e.g. a since-fixed project restriction) would otherwise leave an instance existing-but-incomplete forever, since a naive "only act if the instance is new" guard skips every later run too (confirmed in practice).
  * Host directories are pre-created under `/naspool/immich/{postgres,upload,model-cache}` (configurable via `immich_postgres_dir`/`immich_upload_dir`/`immich_model_cache_dir` in `group_vars/all/00-defaults.yml`) and then **chowned to match each container's shifted UID** — `immich_idmap_base` (`00-defaults.yml`, currently `1000000`) plus the in-container UID the process actually runs as (`999` for postgres, `1000` for node/immich-server, `0`/root for immich-ml, found via a throwaway `incus exec <image> -- id <user>` test). This is necessary because these are unprivileged containers: a plain bind mount device leaves the host path's ownership as-is (`root:root`), so the container's own process can't `chown`/`chmod` its data directory at startup (`Operation not permitted`, confirmed in practice) — and that failed startup left the instance's LXC monitor process dead mid-init without cleaning up its own cgroup, so repeated retries piled up orphaned `lxc.monitor.immich_*-N` cgroups under `/sys/fs/cgroup` until `incus.service` itself needed restarting to clear them. The "correct" fix, `shift=true` (idmapped mounts) on the disk device, is rejected outright by Incus (`the "shift" property cannot be used with a restricted source path`) since `immich.tf` scopes this project's disk access via `restricted.devices.disk.paths` — combining path-restriction with shift is blocked as a privilege-escalation guard. `raw.idmap` is blocked too (needs `restricted.containers.lowlevel`, which this project also doesn't grant). Pre-chowning the host path to the exact shifted UID is the only remaining option under these restrictions.
  * `immich-server`'s `DB_HOSTNAME=immich-db`/`REDIS_HOSTNAME=immich-redis` environment variables rely on Incus's built-in dnsmasq resolving instance names within `immich-br0` (same mechanism as `incusbr0`) — confirmed working (`getent hosts immich-db` from inside `immich-server` resolves correctly). If that ever stops resolving, switch to the instances' static `ipv4.address` instead.
  * The only port exposed to the host/LAN/tailnet is `2283/tcp` (the web UI), via a `proxy` device added directly by this playbook (not Terraform — see `immich.tf`'s own note on why) — Postgres, Redis, and the ML service stay reachable only within `immich-br0`.
  * Requires `immich_db_password` set in the gitignored `group_vars/all/01-local.yml` (kept out of git like `samba_passwords`) before running.
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/immich.yml -K` (needs `-K` for sudo, for the directory-creation/chown tasks only).
  * Reachable at `http://<homelab-ip>:2283`. Verified end-to-end: all 4 instances running, Postgres accepting connections with the `vchord`/`vector` extensions loaded, inter-container DNS resolving, and the web UI returning a normal `200 OK`.

* `src/ansible/playbooks/media.yml` — targets `[myhosts]` (the homelab host itself, over SSH), same reasoning as `immich.yml`: the instances don't exist yet for `incus exec` to target. Deploys four independent Incus OCI application containers into the isolated `media` project created by `src/opentofu/media.tf` — `jellyfin` (`ghcr:jellyfin/jellyfin`, video), `navidrome` (`docker:deluan/navidrome:latest`, music), `kavita` (`docker:jvmilazz0/kavita:latest`, ebooks/PDFs) and `wallos` (`docker:bellamy/wallos:latest`, subscription tracker). Structurally the same as `immich.yml` (`incus init` → `incus config device add` → `incus start`, every step guarded by checking its **own** state fresh rather than a single pre-play "does the instance exist" snapshot), with four deliberate differences:
  * **The media library is mounted read-only and is never chowned.** Each library device carries `readonly=true`, so the services can read and stream `/naspool/biblioteca` but cannot write to it — Samba (`naspool-samba`) remains the only writer. No chown is applied to those paths either: they're already world-readable (dirs `drwxr-xr-x`, files `-rw-r--r--`, owned by uid 993), so the containers' shifted root can read them as-is, and chowning would rewrite the ownership of the user's own archive. This is the opposite of `immich.yml`, where every bind mount is writable and must be pre-chowned.
  * **Jellyfin, Navidrome and Kavita all run as root (uid/gid 0) in-container** — verified by launching each image as a throwaway instance and running `id`, not assumed — so their config directories chown to `media_idmap_base + 0` with no offset.
  * ⚠️ **Wallos is the exception, and needs `media_idmap_base + 82`.** Its php-fpm workers run as `www-data` = **uid 82** (Alpine's numbering, *not* Debian's 33). Note `id` alone is misleading here: it reports uid 0 because PID 1 is root — the real answer came from `ps aux`, which shows `php-fpm: pool www` running as `www-data`. Its instance sets `PUID=82`/`PGID=82`, which upstream's `startup.sh` reads on boot to `usermod` www-data before `chown -R`'ing its data directories.
  * ⚠️⚠️ **`PUID=0` does not work, and fails in two compounding ways.** Setting it to keep the project's chown offset uniform was tried and had to be reverted. First: php-fpm hard-refuses to run a worker pool as root (`ERROR: [pool www] please specify user and group other than root`) and exits — while nginx keeps running, so the container reports RUNNING and every request returns **502 Bad Gateway** rather than failing visibly. Second, and worse: that first boot **persists** `www-data:x:0:82` into the container's own `/etc/passwd`, so simply correcting PUID afterwards doesn't recover — the next boot dies at `usermod: user www-data is currently used by process 1`, and because `startup.sh` runs under `set -euo pipefail` that non-zero exit kills the container at startup (symptom: `incus start` returns success but the instance stays STOPPED, with a misleading `Failed to mount "none" onto .../rootfs/run` in `lxc.log`). Recovery is to **delete and recreate the instance** — safe, since both bind mounts are outside it.
  * `media_idmap_base` (`00-defaults.yml`, `1000000`) was verified empirically for **this** project (`volatile.idmap.current` → `Hostid: 1000000`, `Nsid: 0`) rather than carried over from Immich's — the shift is assigned per-project, so it must not be assumed to match.
  * **Jellyfin gets a `gpu` device** for QuickSync hardware transcoding, which requires `restricted.devices.gpu = "allow"` on the project (`media.tf`). Selected by **PCI address** (`pci=0000:00:02.0`, via `jellyfin_gpu_pci`), *not* by `id=`: Incus's `id` property for a physical GPU means the DRM **card number** (`0` for `card0`), not the render node's filename, so `id=renderD128` fails at instance start with `Failed to start device "gpu": Failed to detect requested GPU device` — confirmed in practice on the first run. No `gid=` property is set: the container runs as root and can open the render node regardless of the host's `render` group (GID 992). ⚠️ Beyond that startup error, this is the single most likely thing to **silently degrade rather than fail** — if the device were present but unusable, Jellyfin falls back to software transcoding with no error, which this host's J5005 cannot sustain. Verify explicitly (see below).
  * **No inter-instance wiring at all** — unlike Immich's `DB_HOSTNAME`/`REDIS_HOSTNAME`, these three never talk to each other, so nothing depends on `media-br0`'s dnsmasq resolving instance names.
  * `media_itunes_dir` (`/naspool/biblioteca/Biblioteca iTunes`) contains a **space**, so its `source=` token is quoted in the device-add command; without quoting the shell splits it and `incus` sees a stray `iTunes` argument.
  * ⚠️ **Mount paths must not nest under a directory the image doesn't already have.** Navidrome's two libraries were first mounted at `/music/Musicas` and `/music/iTunes`, expecting `ND_MUSICFOLDER=/music` to scan the merged tree. That silently produced an **empty library**: since `/music` doesn't exist in the OCI image, Incus creates a `tmpfs` at that path *after* attaching the child mounts, layering it over them and burying both. `/proc/mounts` inside the container showed exactly that — both btrfs mounts followed by `none /music tmpfs`. Fixed by mounting at top-level paths Incus creates directly (`/musicas`, `/itunes`). Jellyfin and Kavita are unaffected because `/media` and `/kavita` already exist in their images — so this only bites where the parent is invented. Note the failure mode: no error anywhere, just an empty library.
  * Consequence of that fix: `ND_MUSICFOLDER` takes a **single** path, so only `/musicas` is scanned (4149 tracks). The iTunes library stays mounted and readable at `/itunes` but is not indexed. To include it, either merge the two host trees under one parent directory and point `ND_MUSICFOLDER` there, or run a second Navidrome instance.
  * Kavita's config path `/kavita/config` is **hardcoded upstream** and must not be changed. Wallos's two paths (`/var/www/html/db`, `/var/www/html/images/uploads/logos`) likewise — they're inside nginx's docroot.
  * **Wallos touches none of `/naspool/biblioteca`.** It's the one service here with no library to index — just its own SQLite database and fetched logos under `/naspool/media/wallos/`. It lives in this project for its trust domain and audience, not its data; a fifth restricted project for one 69MB container would repeat machinery for no isolation gain. Worth revisiting if what it tracks (financial) ever warrants walling off from the media services. Needed **no `media.tf` change at all** — the existing `/naspool/media` prefix in `restricted.devices.disk.paths` already covers it (`tofu plan` → *No changes*).
  * Wallos self-seeds: its `startup.sh` runs `createdatabase.php` then `migrate.php` on every boot, so an empty bind mount is the correct initial state — no template database needs copying in. It also ships its own `crond`, so the ten cronjobs upstream's baremetal instructions list are handled inside the container.
  * Each service exposes exactly one port to the host/LAN/tailnet via its own `proxy` device: Jellyfin `8096`, Navidrome `4533`, Kavita `5000`, Wallos `8282`. Wallos is the only **non-identity** mapping — its nginx listens on plain port `80` in-container, so the device maps host `8282` → container `80`.
  * Requires no secrets — nothing needs adding to the gitignored `01-local.yml` (unlike `immich_db_password`).
  * Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/media.yml -K` (needs `-K` for sudo, for the config-directory creation/chown tasks only).
  * Verified end-to-end on first deploy: all three instances RUNNING on `media-br0`; Jellyfin sees 164 files in Filmes and 1511 in Videos, Navidrome scanned 4149 tracks, Kavita sees 89 PDFs among 705 files; all three library mounts reject writes; all three web UIs respond (`302`/`302`/`200`); QuickSync confirmed with a real VAAPI H.264 encode; `headscale`, `naspool-samba` and all four Immich instances unaffected.

#### Verifying the media stack

Jellyfin's hardware transcoding fails *quietly*, so check it explicitly rather than assuming a green playbook run means it works:

```bash
incus exec jellyfin --project media -- ls -l /dev/dri     # renderD128 must be present
incus exec jellyfin --project media -- ls /media/filmes   # library visible
incus exec jellyfin --project media -- touch /media/filmes/x   # MUST fail (read-only)
```

Device presence alone isn't proof — run a **real VAAPI encode** through Jellyfin's own bundled ffmpeg, which is what actually exercises QuickSync:

```bash
incus exec jellyfin --project media -- /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner \
  -init_hw_device vaapi=va:/dev/dri/renderD128 \
  -f lavfi -i testsrc=size=640x480:rate=1:duration=1 \
  -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null -
```

A successful run ends with a `frame= 1 ... speed=24.6x` line and no errors — confirmed working on this host. (Note that `ls /usr/lib/x86_64-linux-gnu/dri/` inside the container looks *empty* of VAAPI drivers; that's a red herring, since jellyfin-ffmpeg bundles its own at a different path.)

Then play a file and check Jellyfin's **Dashboard → Activity**: it should report `Direct Play`, or `Transcode (hw)` — if it says `Transcode (sw)` the GPU isn't being used.

**Codec coverage.** The J5005's QuickSync accelerates H.264 and HEVC only. Measured across the actual library: `Filmes` is 47 mpeg4 (Xvid) + 28 h264 + 4 msmpeg4v3 + 2 mpeg1video; `Videos` is entirely mpeg2video. So ~58% of Filmes and 100% of Videos cannot use hardware **decode**. That alone is fine — software-decoding Xvid and hardware-encoding H.264 benchmarks at **21×** realtime on this host, and pure software end-to-end still manages **15×**. Old DVD-rip resolutions (620×256, 640×352) are not demanding.

**⚠️ "Enable hardware encoding" must be OFF, or non-H.264/HEVC files fail to play in a browser.** This is an upstream Jellyfin bug, not a configuration error and not a hardware limit. For a source Jellyfin can't hardware-decode (anything in the list above except h264), it still emits a filter chain ending in `hwupload=derive_device=vaapi` while passing **no** `-init_hw_device`/`-vaapi_device`/`-hwaccel`. With the decode in software there is no hardware context to *derive* from, so ffmpeg aborts before writing a frame:

```
Stream #0:0 -> #0:0 (mpeg4 (native) -> h264 (h264_vaapi))
[hwupload] A hardware device reference is required to upload frames to.
Conversion failed!
```

Unchecking MPEG2/VC1/VP8/VP9 under "Enable hardware decoding for" does **not** help — there is no MPEG4 checkbox at all, and the broken chain is generated regardless. The only server-side fix is unchecking **Enable hardware encoding** (Dashboard → Playback → Transcoding), which drops `hwupload` from the chain entirely. Cost: the 28 h264 films lose hardware encoding too, since the toggle is global. Tracked upstream at [jellyfin#14911](https://github.com/jellyfin/jellyfin/issues/14911) and [jellyfin#13071](https://github.com/jellyfin/jellyfin/issues/13071) — re-test after a Jellyfin upgrade and re-enable if fixed.

Worth knowing: the transcode is usually **unnecessary**. Jellyfin's own probe reports `"SupportsDirectPlay": true` for these files — it's browser playback that requests the transcode. Native clients (Jellyfin Android/iOS/Android TV, Infuse, Findroid) direct-play Xvid and MPEG-2 with no transcode, no CPU cost and no quality loss, sidestepping the bug entirely.

**Metadata caveat.** `Filmes` filenames don't follow Jellyfin's `Title (Year).ext` convention, so automatic metadata matching will largely fail there until files are renamed. `Videos` is 1171 `.mod`/`.moi` camcorder files from 2006 and should be added as a **Home Videos and Photos** library type (no scraping). Libraries themselves are configured in each service's web UI — none of the three supports declarative library config, so that step stays manual.

#### One-off reorganization of `/naspool/biblioteca/Livros` (2026-07-28)

Kavita refuses any library whose root contains loose files ("One or more folders contains files at the root. Kavita does not support this.") — it expects one folder per book. `Livros` had 70 files sitting at its root, so it was reorganized **in place**, which also changes what Samba users see. Done manually via two throwaway scripts, not codified as a playbook: it's a one-time data migration against the user's own archive, not reproducible infrastructure. Recorded here so the change isn't a mystery later.

* A BTRFS rollback snapshot was taken first at `/naspool/.snapshots/pre-livros-reorg` (same idiom as `naspool-buckets.yml`'s `pre-incus-buckets`). Restore a file from it with `cp -a /naspool/.snapshots/pre-livros-reorg/biblioteca/Livros/... `; reclaim it once confident with `sudo btrfs subvolume delete /naspool/.snapshots/pre-livros-reorg`.
* **Foldering:** each of the 70 loose root files moved into its own folder named after the file's basename. Three basenames existed as both `.pdf` and `.zip` (e.g. `descartes_discurso_do_metodo`) and deliberately share one folder. Two macOS `.DS_Store` files were deleted. The 5 pre-existing subdirectories were left untouched. Net: 703 files, down from 705.
* **Zip extraction:** 25 `.zip` archives were extracted in place and then removed. They split into two kinds, treated differently:
  * **1 web book** — `livro_l'amazonie.zip` is an old scraped website (15 HTML pages + 57 images, no PDF). Extracted **in full**: the HTML and images *are* the book. Kavita reads EPUB/PDF/CBZ/CBR but **not raw HTML**, so it was additionally converted to EPUB with Calibre's `ebook-convert` (run in a throwaway Incus container with the source bind-mounted read-only, so Calibre and its Qt dependencies were never installed on the homelab host). Two quirks of this 2001-era scrape defeat a naive conversion: `index.htm` is a **frameset**, which Calibre can't follow, and `capa.htm` links its chapters only through JavaScript (`href="javascript:janela2('cap01.htm')"`), which Calibre ignores — so a plain table of contents with real `<a href>` links was generated and converted from instead, with `--input-encoding=iso-8859-1` to keep the Portuguese accents intact. Result: a 497KB EPUB, 13 chapters, 43 images, verified free of mojibake. The original HTML tree is untouched alongside it.
  * **23 document books** — a single PDF (or one CHM), extracted; the bundled `Ateus.net.url` download-site advert was skipped (20 of them). 5 PDFs already existed on disk byte-identical and were not duplicated.
  * **1 corrupt archive** — `Awk Languaje Programming- Enero 1996.zip` was 0 bytes and not a zip at all (verified 0 bytes in the snapshot too, so empty since 2006). Deleted along with its then-empty folder.
* Net effect: 90 files extracted, all 25 zips removed, 17 genuinely new PDFs (Camus, Kant, Dante, Foucault, Sade…) now visible to Kavita that were previously locked inside archives. Verified after the fact: 0 files at the root, 0 zips remaining, 69 subdirectories, **106 PDFs (up from 89)**, 767 files total, and L'Amazonie's 15 HTML pages intact.

* `src/ansible/playbooks/coolify.yml` — installs [Coolify](https://coolify.io) (a self-hosted PaaS) into the `coolify` instance and prepares `coolify-sandbox` to act as a Coolify "remote server". Both instances are created by `src/opentofu/coolify.tf`. Targets `[myhosts]` over SSH rather than `incus exec`, for the same reason as `immich.yml`/`media.yml`: the tasks drive the `incus` CLI itself, and at first run the instances aren't guaranteed to exist.

  **What it's for.** Coolify's service catalogue is far larger than what this repo models by hand, so it's used as an **evaluation scratchpad**: try an app in a couple of clicks, and if it earns a permanent place, provision it properly with OpenTofu + Ansible. Nothing is meant to live here long-term, which is why the sandbox has no access to `/naspool` or any host path (enforced by the project's restrictions — see `references/OPENTOFU.md`).

  This is the only playbook here that installs Docker and runs an upstream install script inside a container. That's inherent to Coolify: its control plane *is* a Docker Compose stack, and the apps it deploys are Docker containers. Structure:
  * **Control plane** — installs curl/ca-certificates, pre-seeds `.env`, runs upstream's installer, then polls the `coolify` container's own Docker healthcheck rather than sleeping a fixed interval. Guarded on `/data/coolify` existing so it runs exactly once; re-running the installer is an *upgrade*, which should be deliberate rather than a side effect of re-running the playbook.
  * **Sandbox** — installs `openssh-server` (the Debian 13 image has none) and Docker, then sets `PermitRootLogin prohibit-password`. Coolify drives its servers entirely over SSH as root, running `docker` commands remotely.
  * **Key handoff** — reads the **public** half of the keypair Coolify generated for itself at install time out of its container, and installs it in the sandbox's `/root/.ssh/authorized_keys`. The private half never leaves Coolify's container and no private key enters this repo. The effect is that enrollment in the UI is just *Servers → Add* with the IP the playbook prints at the end.

  **⚠️ The Docker network pool must be overridden, and it's set *before* the installer first runs.** Coolify defaults `DOCKER_ADDRESS_POOL_BASE` to `10.0.0.0/8`, which contains **every** Incus bridge on this host — `immich-br0` (10.10.10), `media-br0` (10.10.20), `coolify-br0` (10.10.30) and `incusbr0` (10.183.191). Docker only carves out a `/24` at a time as apps are created, so a collision wouldn't appear at install: it would surface much later as one of those bridges mysteriously breaking, with nothing obviously connecting it to Coolify. `coolify_network_pool` pins it to `10.99.0.0/16` instead, written into `/data/coolify/source/.env` before first boot so no `10.0.0.0/8` network is ever created. Verified after deploy: Coolify's networks sit on `10.99.0.0/24` and `10.99.1.0/24`.

  **The sandbox needs its own `daemon.json`, for a different reason than the control plane.** The sandbox never runs Coolify's installer (it's a deploy target, not a control plane), so nothing writes one for it and Docker falls back to its built-in default of `172.16.0.0/12`. That doesn't collide with anything here — but Docker's default carves out a **`/16` per network**, and Coolify creates one per project, so the range is exhausted after ~16 projects with an opaque "no available, non-overlapping IPv4 address pool" error mid-deploy. `coolify_sandbox_network_pool` pins it to `10.98.0.0/16` with `/24` sizing (256 networks), deliberately a *different* `/16` from the control plane's `10.99.0.0/16` — the two daemons allocate independently with no knowledge of each other, so a shared range would eventually have both pick the same subnet. Note that changing this only affects **newly created** networks; pre-existing ones keep their original subnet until recreated.

  That last caveat bit once, and is worth recording. The sandbox's `coolify` network was created by the installer *before* the daemon restart that picked up `daemon.json`, so it kept Docker's default `172.18.0.0/16` while the `bridge` network (created after) correctly got `10.98.0.0/24`. Harmless — nothing on this host uses `172.16/12` — but not what the config said. Fixed by recreating it, which requires detaching the one container on it:

  ```bash
  incus exec coolify-sandbox --project coolify -- docker stop coolify-proxy
  incus exec coolify-sandbox --project coolify -- docker network rm coolify
  incus exec coolify-sandbox --project coolify -- docker network create --attachable coolify
  incus exec coolify-sandbox --project coolify -- docker network connect coolify coolify-proxy
  incus exec coolify-sandbox --project coolify -- docker start coolify-proxy
  ```

  Safe here because the network is `coolify.managed=true` (Coolify recreates it on demand), nothing on disk under `/data` referenced the old subnet, and the sandbox had no deployed apps. It came back on `10.98.1.0/24`. **Check for this after any change to a `default-address-pools` setting** — the daemon only applies it to networks it creates afterwards.

  **⚠️ `incus file push` silently writes to the wrong container if you omit the remote.** The target is `<remote>:<instance>/<path>`, and leaving the remote off is *not* an error — `incus file push f coolify/coolify-sandbox/etc/docker/daemon.json` parses as instance `coolify`, path `/coolify-sandbox/etc/docker/daemon.json`, dropping the file into the **control plane** at a nonsense path and returning **rc=0**, so Ansible reports success while the intended container is untouched. Confirmed in practice here. This playbook writes files with `incus exec <inst> -- sh -c "cat > <path>"` and the task's `stdin:` instead, where the instance is an unambiguous separate argument.

  **Two `incus exec` guard gotchas**, both found by the playbook failing its own idempotency check (`changed=3` on a second run):
  * `incus exec <inst> -- command -v docker` **always** fails with rc=127. `command` is a shell builtin, not an executable, and `incus exec` runs the binary directly with no shell. The guard silently never matched, so Docker was reinstalled on every run. Needs `-- sh -c "command -v docker"`. `test` and `grep` are real binaries in `/usr/bin`, so the other guards are fine as-is.
  * `changed_when: <reg>.rc == 0` on the `sed`-based sshd task marked it changed on every run — `sed -i` succeeds whether or not it substituted anything. Replaced with a preceding `grep -qx` check that the desired line is already present.

  Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/coolify.yml` (no `-K`: every task runs inside a container via `incus exec`, and nothing needs root on the host).

### Verifying Coolify

Feasibility was established empirically before any of this was written, in throwaway Incus containers that were then deleted:

| Check | Result |
|---|---|
| Docker nested in an unprivileged Incus container | Works — Docker **29.6.2** |
| Docker storage driver | **overlayfs** — *not* the vfs/btrfs fallbacks the usual "don't run Docker in LXC" warnings concern |
| Multi-service compose stack (nginx + postgres) | Up, including port publishing and Postgres initdb |
| Coolify installer | **4.1.2**, all containers healthy |
| Coolify → sandbox SSH **from inside the `coolify` app container** | Succeeded; remote Docker reported `29.6.2`/`overlayfs` |

That last row is the decisive one — it's the exact code path Coolify's own server validation uses.

After deploying, check:

```bash
incus list --project coolify -f compact                      # both RUNNING on 10.10.30.0/24
incus exec coolify --project coolify -- docker ps            # 6 containers, all healthy
incus exec coolify --project coolify -- docker network inspect bridge \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'        # must be 10.99.x, never 10.10.x/10.183.x
```

The web UI is at `http://<homelab-ip>:8000` (HTTP 200, title "Coolify"). First visit creates the admin account. Then **Servers → Add** using the sandbox IP the playbook printed, user `root`, with Coolify's own pre-installed key — validation should pass immediately.

Confirm the isolation guarantee still holds — Incus should *refuse* this:

```bash
incus config device add coolify-sandbox evil disk source=/naspool path=/naspool --project coolify
# Error: ... Attaching disks not backed by a pool is forbidden
```

**Teardown**, since disposability is the point: `incus delete --force coolify coolify-sandbox --project coolify`, or `tofu destroy` targeting the two instances. Nothing is written outside the containers — verified that the host keeps no Docker and no `/data`.

* `src/ansible/playbooks/dashboard.yml` — renders the **services dashboard**: one static HTML page listing every service on this homelab and the port it runs on, served by the Caddy that already runs inside the `headscale` instance.

  **What it's for.** Every port here was already documented, but only as prose inside whichever reference file matched *how* the thing was provisioned (this file, `OPENTOFU.md`, `INSTALL.md`, `ARCHITECTURE.html`), so answering "what's on 5000 again?" meant grepping four files. There was no artifact organised by **service**, which is how the question actually gets asked.

  **The page is generated, not written.** It's rendered from `templates/services.html.j2` using the port variables already in `group_vars/all/00-defaults.yml` — so the defaults stay the single source of truth and the page is a build artifact of them. A hand-maintained list would be the same class of thing as the docs that already drift, which is the whole problem. **Never edit the rendered `index.html`;** change the variable and re-run.

  **No dedicated Incus project, unlike `immich.yml`/`media.yml`/`coolify.yml`.** The first cut gave the dashboard its own restricted project, bridge and nginx OCI container — structurally consistent, and far too much machinery for one static file. Caddy is already running in the `headscale` container, is already managed by this repo's own `Caddyfile.j2`, and `file_server` is a first-class directive in it rather than a workaround. Reusing it costs two devices on `headscale.tf` instead of a fifth project. Accepted tradeoff: that container is no longer purely "the tailnet controller", and the page's availability is tied to it.

  **Two plays, connecting differently** — the structural point of the file:
  * The first targets `[myhosts]` over SSH with `become: true`, because the page has to be rendered on the **host** side of the bind mount.
  * The second targets `[headscale_hosts]` via `incus exec`, like `headscale.yml`/`headplane.yml`, because that's where Caddy lives. It re-renders the shared `Caddyfile.j2`, runs `caddy validate` before reloading (a malformed Caddyfile would take the public headscale endpoint down with it), and polls until the page answers `200`.

  **⚠️ The dashboard binds `8081` inside the container, not `8080`.** Port `8080` in the `headscale` container is already **headscale's own plain-HTTP API listener** — the one the public `<headscale-domain>` Caddy block reverse-proxies to. Binding the dashboard there would collide with it. The proxy device therefore maps host `8080` → container `8081` (`dashboard_port` vs `dashboard_internal_port`). Also occupied inside that container: `3000` headplane, `2019` Caddy's admin API, `9090` headscale metrics.

  **⚠️ It's a separate Caddy listener, not a path under the public site block.** That block is internet-facing; this page is a complete map of every internal service and port here. Serving it there — even behind a `remote_ip` matcher — would leave one typo between that map and the public internet. On its own bare `:8081` listener it gets exactly the exposure of every other service: the host's own address, so LAN and tailnet, and nothing the router forwards. Note also that publishing it would gain little, since every link on it points at `homelab:PORT`, which only resolves on the LAN or tailnet.

  **No embedded webfonts,** unlike `references/ARCHITECTURE.html`. That file is opened straight off the filesystem so it must carry its own ~770KB of base64 fonts; this one is served over HTTP, where a system font stack costs nothing and keeps three quarters of a megabyte of base64 out of git.

  **No render timestamp in the page,** deliberately — `ansible_date_time` changes every run, so embedding it would rewrite the file each time and report `changed` forever, failing the standing `changed=0` bar. The page is a pure function of the variables.

  The two devices it depends on (the read-only `/naspool/dashboard` mount and the `8080` proxy) are declared in `src/opentofu/headscale.tf`, and the playbook **checks they exist and fails with a useful message** if `tofu apply` hasn't been run — a missing mount otherwise produces a confusing 404 rather than an obvious failure.

  Run with: `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/dashboard.yml -K` (needs `-K` for sudo, for the docroot creation/render tasks on the host only).

#### Verifying the dashboard

```bash
incus config device show headscale | grep -A3 dashboard   # both devices present
curl -sI http://<homelab-ip>:8080/                        # 200
incus exec headscale -- touch /var/www/dashboard/x        # must fail: read-only file system
```

Then re-run the playbook and confirm **`changed=0`**. The property the whole design exists for: change one port in `00-defaults.yml`, re-run, and the page reflects it.

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

## Upgrading Immich

**Bumping `immich_version` alone does nothing.** `immich.yml` creates each instance only when it doesn't already exist, so re-running it after a bump reports `changed=0` and leaves the old version running. The two app instances must be deleted first so the playbook recreates them from the new tag.

This is safe because `immich-server` and `immich-ml` hold **no state** — their only devices are bind mounts (`/naspool/immich/upload`, `/naspool/immich/model-cache`), and the database lives in the separate `immich-db` instance, which this procedure never touches.

1. **Check the release notes** for breaking changes and migration steps: https://github.com/immich-app/immich/releases
2. **Check whether Postgres moved too.** `immich_postgres_image` is pinned separately since it changes far less often. Compare it against `image:` in upstream's [`docker/docker-compose.yml`](https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml) — if the pinned tag there differs, bump both in the same pass.
3. **Bump `immich_version`** in `src/ansible/group_vars/all/00-defaults.yml` to the target tag (e.g. `v3.1.0`).
4. **Delete the two stateless app instances:**
   ```bash
   incus delete --force immich-server immich-ml --project immich
   ```
   Immich is down from here until step 5 completes.
5. **Re-run the playbook** (from WSL; needs `-K`, the homelab requires a sudo password):
   ```bash
   ansible-playbook -i src/ansible/hosts src/ansible/playbooks/immich.yml -K
   ```
   Immich runs its own schema migrations when `immich-server` next starts.
6. **Verify** the version actually moved — the API is authoritative, `incus config get <instance> image.version` is empty for these OCI instances:
   ```bash
   incus exec immich-server --project immich -- curl -s http://localhost:2283/api/server/version
   ```
   Then open the web UI and confirm the library is intact, rather than trusting the version number alone.

**Pin a concrete tag, never `release`.** This variable was `release` (a floating tag) until 2026-08-17. Two problems that caused: the repo stopped being able to answer "what version is deployed?" — you had to query the running server — and any rebuild would silently jump versions. The delete-and-recreate above is precisely what makes a floating tag dangerous here.

