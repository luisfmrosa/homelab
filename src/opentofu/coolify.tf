# Isolation for Coolify: its own Incus project and a dedicated bridge
# network, same pattern as immich.tf/media.tf — see immich.tf's header for
# the full reasoning on why a plain bridge network can't live inside a
# non-default project (only OVN can), and why `features.profiles = true`
# plus an explicitly-declared default profile are both required before a
# project can be `restricted`.
#
# WHAT THIS IS FOR. Coolify is a self-hosted PaaS: a control plane with a
# large service catalogue, which deploys apps onto "servers" it reaches over
# SSH. It's deliberately NOT the way this homelab runs anything permanent —
# OpenTofu + Ansible stay the path for that. Coolify is here as a
# *scratchpad*: a way to try an app from its catalogue in a couple of clicks
# and decide whether it's worth provisioning properly. Both halves therefore
# live on this one physical host as sibling containers:
#   coolify          — the control plane (its own 4-container Docker stack)
#   coolify-sandbox  — a throwaway "remote server" it deploys onto
#
# WHY THE INSTANCES ARE DECLARED HERE, unlike immich.tf/media.tf. Those two
# deliberately leave instance creation to Ansible because the lxc/incus
# provider has an open bug (issues/348) breaking OCI remote/image
# resolution. That bug is specific to OCI ("application container") images.
# These two are plain `images:debian/13` SYSTEM containers — exactly what
# headscale.tf and naspool.tf already declare successfully — so there's no
# reason to work around it here. Ansible still does everything *inside* the
# containers (src/ansible/playbooks/coolify.yml).
resource "incus_network" "coolify_br0" {
  name = "coolify-br0"
  type = "bridge"

  config = {
    # Next free /24 after immich-br0 (10.10.10) and media-br0 (10.10.20).
    # Note this is NOT the same range as Coolify's own per-app Docker
    # networks, which coolify.yml pins to 10.99.0.0/16 — see the
    # coolify_network_pool variable for why that matters.
    "ipv4.address" = "10.10.30.1/24"
    "ipv4.nat"     = "true"
    "ipv6.address" = "none"
  }
}

resource "incus_project" "coolify" {
  name        = "coolify"
  description = "Coolify PaaS: control plane + disposable sandbox server"

  config = {
    "features.images"            = false
    "features.profiles"          = true
    "features.networks"          = false
    "restricted"                 = true
    "restricted.networks.access" = incus_network.coolify_br0.name
    "restricted.devices.nic"     = "managed"

    # NEW vs immich.tf/media.tf — restricted.containers.nesting defaults to
    # "block", and without this neither container can run Docker at all
    # (Coolify itself IS a Docker Compose stack, and its sandbox servers run
    # the apps it deploys). Nesting has to be granted at the project level;
    # there is no per-instance override that works inside a restricted
    # project.
    #
    # Be clear about the cost: nesting plus the mknod/setxattr syscall
    # interception on the instances below is a genuinely weaker isolation
    # posture than anything else in this repo. A container running a nested
    # Docker daemon has a broader kernel attack surface than one running a
    # plain service. That is exactly why this project is scoped the way it
    # is, and why the sandbox is treated as disposable rather than as
    # somewhere to keep anything.
    "restricted.containers.nesting" = "allow"

    # Nesting alone isn't enough: the two security.syscalls.intercept.*
    # keys on the instances below are gated by a *separate* restriction,
    # which also defaults to "block" (confirmed the hard way — instance
    # creation failed with "Container syscall interception is forbidden"
    # even with nesting already allowed).
    #
    # "allow" rather than "full": it permits the interception options Incus
    # considers safe — which is exactly the mknod/setxattr pair Docker needs
    # — while continuing to block filesystem mounting interception. "full"
    # would additionally allow that, and nothing here needs it.
    "restricted.containers.interception" = "allow"

    # Deliberately absent: restricted.devices.disk (+ .paths).
    #
    # immich.tf and media.tf both have to grant it, because their instances
    # bind-mount host paths (/naspool/immich, /naspool/biblioteca). Nothing
    # here does. Leaving it at its restricted default of "managed" means an
    # instance in this project can only ever use pool-backed disks — a plain
    # host-path bind mount is refused by Incus with "Attaching disks not
    # backed by a pool is forbidden".
    #
    # That is the concrete mechanism keeping a disposable, nesting-enabled
    # sandbox away from /naspool and every other real path on the host. It's
    # enforced by Incus rather than by remembering not to do it, which
    # matters more here than in the other projects precisely *because* this
    # one runs arbitrary catalogue apps that were never reviewed.

    # Needed for the control plane's web UI proxy device below. As noted in
    # immich.tf, Incus has no restricted.devices.proxy.* allowlist to scope
    # this to a single port, so it's all-or-nothing per project.
    "restricted.devices.proxy" = "allow"
  }
}

# Same chicken-and-egg as immich.tf/media.tf: the profile needs
# features.profiles=true already active on the project, while the project's
# restricted.networks.access needs this profile's eth0 already pointed at
# coolify-br0 rather than the incusbr0 it would otherwise inherit by being
# copied from the default project. If `tofu apply` fails on first creation
# with "Invalid device 'eth0' on profile 'default' of project 'coolify':
# Network not allowed in project", apply once with the project's
# "restricted*" keys commented out, then restore them and apply again.
# Re-applying from there on is idempotent.
resource "incus_profile" "coolify_default" {
  name    = "default"
  project = incus_project.coolify.name

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.coolify_br0.name
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

# The Coolify control plane. Runs its own 4-container Docker Compose stack
# (coolify, coolify-db, coolify-redis, coolify-realtime), installed by
# coolify.yml via the upstream install script.
resource "incus_instance" "coolify" {
  name    = "coolify"
  project = incus_project.coolify.name
  image   = "images:debian/13"

  config = {
    "boot.autostart" = true

    # The three keys that make a nested Docker daemon work in an
    # unprivileged container, verified in practice on this host (kernel
    # 6.12.95, Incus 7.2): Docker 29.6.2 installs and runs, and picks the
    # *overlayfs* storage driver rather than falling back to vfs. That
    # matters — the widely-repeated advice against running Docker in LXC
    # mostly concerns the vfs/btrfs fallbacks, which are slow and fragile.
    # Requires restricted.containers.nesting = "allow" on the project above.
    "security.nesting"                     = true
    "security.syscalls.intercept.mknod"    = true
    "security.syscalls.intercept.setxattr" = true
  }

  # Apps deployed onto the sandbox are not exposed automatically — add a
  # proxy device per app, on the sandbox instance, when one is actually
  # worth reaching from the LAN.
  device {
    name = "coolify-web"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:8000"
      connect = "tcp:127.0.0.1:8000"
    }
  }

  # Coolify's realtime (websocket) service, which pushes live deployment
  # logs and server/proxy status into the UI. Unlike the API, the *browser*
  # connects to these directly, so forwarding 8000 alone isn't enough —
  # without them the UI shows "Cannot connect to real-time service" and
  # status indicators go stale (e.g. reporting "Proxy Exited" for a proxy
  # that is in fact running and healthy).
  #
  # These were initially left closed on the principle of exposing nothing
  # speculatively, then added once the UI actually demanded them.
  device {
    name = "coolify-realtime-ws"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:6001"
      connect = "tcp:127.0.0.1:6001"
    }
  }

  device {
    name = "coolify-realtime-api"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:6002"
      connect = "tcp:127.0.0.1:6002"
    }
  }
}

# The sandbox "remote server". Identical to the control plane except it
# exposes nothing to the host: Coolify reaches it over SSH on coolify-br0
# (root + a key Coolify generates itself, installed by coolify.yml), and
# that traffic never leaves the bridge.
#
# Adding a second sandbox is a one-line change here plus an entry in
# coolify_sandboxes in group_vars/all/00-defaults.yml.
resource "incus_instance" "coolify_sandbox" {
  name    = "coolify-sandbox"
  project = incus_project.coolify.name
  image   = "images:debian/13"

  config = {
    "boot.autostart"                       = true
    "security.nesting"                     = true
    "security.syscalls.intercept.mknod"    = true
    "security.syscalls.intercept.setxattr" = true
  }
}
