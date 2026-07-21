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
}
