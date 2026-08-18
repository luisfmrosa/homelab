# Isolation for the media stack (Jellyfin, Navidrome, Kavita) plus Wallos:
# its own Incus project and a dedicated bridge network, exactly the same
# pattern as
# immich.tf — see that file's header for the full reasoning on why a plain
# bridge network can't live inside a non-default project (only OVN can), and
# why `features.profiles = true` plus an explicitly-declared default profile
# are both required before a project can be `restricted`.
#
# Every service here is a single, independent OCI "application container"
# with no inter-service traffic at all (unlike Immich's server <-> db/redis/ml
# chatter) — they're grouped into one project because they share a trust
# domain and an audience, not because they need to talk to each other. One
# project keeps the restriction set declared once instead of four times over.
#
# Wallos (subscription tracker) is the odd one out: it shares the audience
# and the single-container shape, but not the data source — it never touches
# /naspool/biblioteca, only its own /naspool/media/wallos. It's here rather
# than in a project of its own because a fifth restricted project for one
# 69MB container repeats machinery for no isolation gain. Worth revisiting
# if it ever holds data you'd want walled off from the media services, since
# what it tracks is financial rather than a film library.
#
# As with Immich, the instances themselves are NOT declared here as
# incus_instance resources — the lxc/incus provider has an open bug
# (https://github.com/lxc/terraform-provider-incus/issues/348) breaking OCI
# remote/image resolution — so instance creation, their disk/gpu/proxy
# devices and startup all live in src/ansible/playbooks/media.yml instead.
resource "incus_network" "media_br0" {
  name = "media-br0"
  type = "bridge"

  config = {
    # 10.10.10.0/24 is immich-br0's; this project gets its own /24 so the
    # two never overlap even though both are NAT'd behind the same host.
    "ipv4.address" = "10.10.20.1/24"
    "ipv4.nat"     = "true"
    "ipv6.address" = "none"
  }
}

resource "incus_project" "media" {
  name        = "media"
  description = "Media stack: Jellyfin, Navidrome, Kavita (isolated project)"

  config = {
    "features.images"            = false
    "features.profiles"          = true
    "features.networks"          = false
    "restricted"                 = true
    "restricted.networks.access" = incus_network.media_br0.name
    "restricted.devices.nic"     = "managed"
    # Same reasoning as immich.tf: restricted projects default
    # restricted.devices.disk to "managed" (pool-backed disks only), which
    # blocks the plain host-path bind mounts these services need. Scoped
    # down again by restricted.devices.disk.paths — two prefixes here
    # rather than Immich's one:
    #   /naspool/biblioteca — the pre-existing media library, mounted
    #     READ-ONLY (see media.yml). This is the user's own archive, also
    #     exported read-write over Samba by naspool-samba; the media
    #     services deliberately get no write access to it at all.
    #   /naspool/media — writable config/cache/database for the services
    #     themselves, created fresh by media.yml. Kept entirely separate
    #     from the library so a service can never scribble into the archive
    #     it's indexing. Wallos's SQLite database and logo uploads live
    #     under here too (/naspool/media/wallos/), so it needs no new path
    #     prefix — the existing grant already covers it.
    "restricted.devices.disk"       = "allow"
    "restricted.devices.disk.paths" = "/naspool/biblioteca,/naspool/media"
    # Needed for each service's web UI proxy device (Jellyfin 8096,
    # Navidrome 4533, Kavita 5000) — restricted projects block proxy
    # devices outright, and Incus has no finer per-port allowlist, so it's
    # all-or-nothing per project (same limitation noted in immich.tf).
    "restricted.devices.proxy" = "allow"
    # NEW vs immich.tf — restricted.devices.gpu defaults to "block", so
    # without this Jellyfin cannot be given the host's /dev/dri render node
    # at all. This is a deliberately broader grant than the disk/proxy ones
    # above: unlike disk (scoped by .paths), Incus has no
    # restricted.devices.gpu.* allowlist, so it permits any GPU device in
    # the project rather than just Jellyfin's renderD128.
    #
    # It's accepted here because the alternative is worse in practice: this
    # homelab's CPU is an Intel Pentium Silver J5005 (Gemini Lake, 4 weak
    # cores), where software transcoding a single 1080p stream is not
    # realistically viable. QuickSync via /dev/dri/renderD128 is what makes
    # Jellyfin usable at all — see media.yml's gpu device and the "Codec
    # coverage" note in references/ANSIBLE.md for which formats it actually
    # accelerates (H.264/HEVC yes; the library's MPEG-2/Xvid no).
    "restricted.devices.gpu" = "allow"
  }
}

# Same chicken-and-egg as immich.tf's equivalent resource: the profile needs
# features.profiles=true already active on the project, while the project's
# restricted.networks.access needs this profile's eth0 already pointed at
# media-br0 rather than the incusbr0 it would otherwise inherit by being
# copied from the default project. If `tofu apply` fails on first creation
# with "Invalid device 'eth0' on profile 'default' of project 'media':
# Network not allowed in project", apply once with the project's
# "restricted*" keys commented out, then restore them and apply again.
# Re-applying from there on is idempotent.
resource "incus_profile" "media_default" {
  name    = "default"
  project = incus_project.media.name

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.media_br0.name
    }
  }

  device {
    name = "root"
    type = "disk"

    properties = {
      path = "/"
      pool = "default"
    }
  }
}
