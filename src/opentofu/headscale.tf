resource "incus_instance" "headscale" {
  name  = "headscale"
  image = "images:debian/12"

  config = {
    "boot.autostart" = true
  }

  # Default NAT'd incusbr0 bridge, not a macvlan on the homelab's wlo1. A
  # macvlan NIC was tried first so the container could get its own IPv6
  # directly from the router, but macvlan doesn't work reliably over WiFi —
  # access points generally only accept traffic for the one MAC they
  # associated with, so a second virtual MAC riding the same radio gets
  # silently dropped (confirmed: the container had a global IPv6 and a
  # default route, but zero actual reachability — ping and DNS both hung).
  # Exposed to the internet instead via the "proxy" devices below, forwarding
  # from the homelab host's own wlo1 address (which does have a real route)
  # to this container's internal NAT'd address. See the "headscale" section
  # in references/INSTALL.md for the router firewall rule pointing at the
  # homelab host itself.
  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = "incusbr0"
    }
  }

  device {
    name = "https"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:443"
      connect = "tcp:127.0.0.1:443"
    }
  }

  device {
    name = "http-acme"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:80"
      connect = "tcp:127.0.0.1:80"
    }
  }

  device {
    name = "derp-stun"
    type = "proxy"

    properties = {
      listen  = "udp:0.0.0.0:3478"
      connect = "udp:127.0.0.1:3478"
    }
  }

  # --- services dashboard (see dashboard.yml) ---
  #
  # A single generated HTML page listing every service on this homelab and
  # the port it's on, rendered on the HOST by dashboard.yml from the port
  # variables in group_vars/all/00-defaults.yml, and served by the Caddy that
  # already runs in this container.
  #
  # WHY HERE, rather than in a project of its own. The first cut of this gave
  # the dashboard its own restricted Incus project, bridge and nginx OCI
  # container — structurally consistent with immich/media/coolify, but a lot
  # of machinery for one static file. Caddy is already running here, already
  # managed by this repo's own Caddyfile template, and file serving is a
  # first-class directive in it (`file_server`), not a workaround. Reusing it
  # costs two devices instead of a fifth project.
  #
  # The tradeoff accepted: this container is no longer purely "the tailnet
  # controller", and the page's availability is tied to it. Both are cheap
  # next to the alternative.
  device {
    name = "dashboard"
    type = "disk"

    properties = {
      source = "/naspool/dashboard"
      path   = "/var/www/dashboard"
      # nginx-style docroots are read-only by nature, and this one doubly so:
      # the page is only ever written on the host by Ansible, never from
      # inside the container. There is no code path where Caddy legitimately
      # writes here, so the mount is configured to match.
      readonly = "true"
    }
  }

  # Deliberately a SEPARATE listener from the public :443 site block, not a
  # path under it. That block is <headscale-domain> — forwarded by the
  # router and reachable from the open internet — and this page is a map of
  # every internal service and port. Serving it there, even behind a
  # remote_ip matcher, puts one typo between the map and the public.
  #
  # On its own port it has exactly the exposure of every other service in
  # this homelab: the host's own address, so LAN and tailnet, and nothing the
  # router forwards. See the ":8081" block in templates/Caddyfile.j2.
  #
  # Note the two ports differ. The container-side one is NOT 8080 — that's
  # headscale's own plain-HTTP API listener in here, which the public Caddy
  # block reverse-proxies to, so binding the dashboard there would collide.
  # (Also in use inside this container: 3000 headplane, 2019 Caddy's admin
  # API, 9090 headscale metrics.)
  #
  # Both come from variables that MUST be kept in step with their namesakes
  # in src/ansible/group_vars/all/00-defaults.yml — see the long note in
  # variables.tf. Ansible renders the port into the page's text; this device
  # is what actually forwards it. Changing only the Ansible side produces a
  # page that confidently prints a port nothing is listening on.
  device {
    name = "dashboard-web"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:${var.dashboard_port}"
      connect = "tcp:127.0.0.1:${var.dashboard_internal_port}"
    }
  }
}
