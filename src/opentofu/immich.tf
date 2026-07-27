# Isolation for the Immich photo management stack: its own Incus project
# and a dedicated bridge network, separate from the "default" project's
# incusbr0 (used by headscale and naspool-samba). Keeps Immich's internal
# service-to-service traffic (server <-> db/redis/ml) off the same L2 as
# everything else, not just namespaced by project.
#
# The 4 Immich services themselves (immich-server, immich-ml, immich-db,
# immich-redis) are NOT declared here as incus_instance resources. They run
# as Incus OCI "application containers" (`incus launch docker:...`/
# `incus launch ghcr:...`), and the lxc/incus provider has an open bug
# (https://github.com/lxc/terraform-provider-incus/issues/348) that breaks
# OCI remote/image resolution for incus_instance. Instance creation and the
# web UI's proxy device are handled by src/ansible/playbooks/immich.yml
# instead (see references/ANSIBLE.md), the same way that playbook's
# `incus launch` calls use the `docker`/`ghcr` OCI remotes already
# configured by incus.yml.
#
# Only OVN networks can live inside a non-default Incus project — plain
# bridge networks (like incusbr0) are always global, project-agnostic
# resources (confirmed against Incus's own docs/forum: "Network type does
# not support non-default projects" is a hard validation, not a config
# gap). So immich-br0 is declared here in the default project like
# incusbr0, and isolation is enforced the way Incus expects for
# bridge-only setups: the "immich" project is `restricted`, and
# `restricted.networks.access` limits it to using only this one bridge —
# instances in this project cannot attach to incusbr0 or any other
# network, and `restricted.devices.nic = "managed"` stops them from
# bypassing that via an unmanaged/parent-based NIC device.
# `features.profiles = true` is required by Incus for any restricted
# project ("Projects without their own profiles cannot be restricted") —
# it gives "immich" its own default profile, separate from the default
# project's (which still points eth0 at incusbr0). That profile is
# declared explicitly below (incus_profile.immich_default) with eth0
# pointed at immich-br0 instead — otherwise Incus initializes a new
# project's default profile by copying the default project's one
# verbatim (eth0 -> incusbr0), which then conflicts with
# restricted.networks.access below ("Network not allowed in project").
resource "incus_network" "immich_br0" {
  name = "immich-br0"
  type = "bridge"

  config = {
    "ipv4.address" = "10.10.10.1/24"
    "ipv4.nat"     = "true"
    "ipv6.address" = "none"
  }
}

resource "incus_project" "immich" {
  name        = "immich"
  description = "Immich photo management stack (isolated project)"

  config = {
    "features.images"            = false
    "features.profiles"          = true
    "features.networks"          = false
    "restricted"                 = true
    "restricted.networks.access" = incus_network.immich_br0.name
    "restricted.devices.nic"     = "managed"
    # Restricted projects default restricted.devices.disk to "managed",
    # which only allows disk devices backed by an Incus storage pool
    # (pool=...) — confirmed in practice: adding a plain host-path bind
    # mount (like naspool-samba's in the unrestricted default project)
    # failed with "Attaching disks not backed by a pool is forbidden".
    # "allow" restores normal bind-mount support, scoped down again by
    # restricted.devices.disk.paths to only the one host path prefix
    # Immich's instances actually need (see immich.yml's disk devices) —
    # narrower than naspool-samba's equivalent, which has no such limit.
    "restricted.devices.disk"       = "allow"
    "restricted.devices.disk.paths" = "/naspool/immich"
    # Same story as restricted.devices.disk above, but for proxy devices
    # (confirmed: adding immich-server's web UI proxy device failed with
    # "Proxy devices are forbidden" until this was set) — restricted
    # projects default restricted.devices.proxy to "block". Unlike disk,
    # Incus has no equivalent restricted.devices.proxy.* allowlist to
    # scope this down to just port 2283, so it's all-or-nothing per
    # project; only immich.yml's own single "immich-web" device on
    # immich-server actually uses it in practice.
    "restricted.devices.proxy" = "allow"
  }
}

# incus_profile.immich_default and incus_project.immich each implicitly
# depend on the other (the profile needs features.profiles=true already
# active on the project; the project's restriction needs the profile's
# eth0 already pointed at immich-br0, not the inherited incusbr0) — a
# genuine chicken-and-egg Incus itself can't resolve in one API call.
# Applied here in two passes: first with the project's "restricted*" keys
# commented out (so only features.profiles=true takes effect and this
# profile gets created/pointed at immich-br0), then with them restored.
# Re-applying from here on is idempotent as normal.
resource "incus_profile" "immich_default" {
  name    = "default"
  project = incus_project.immich.name

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.immich_br0.name
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
