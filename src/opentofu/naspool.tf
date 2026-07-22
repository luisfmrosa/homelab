resource "incus_instance" "naspool" {
  name  = "naspool-samba"
  image = "images:debian/12"

  config = {
    "boot.autostart" = true
  }

  device {
    name = "naspool"
    type = "disk"

    properties = {
      path   = "/naspool"
      source = "/naspool"
    }
  }

  # Named "naspool-samba" rather than "naspool" to disambiguate it from the
  # host's /naspool BTRFS mount and the (planned) "naspool-buckets" Incus
  # storage pool — "naspool" alone was ambiguous across all three.
  #
  # Default NAT'd incusbr0 bridge (same as headscale.tf) — no cloud-init
  # user/SSH is provisioned; Ansible connects via the community.general.incus
  # connection plugin (incus exec, as root) instead, same as the "headscale"
  # instance. Exposed to the LAN and tailnet via the proxy device below,
  # forwarding from the homelab host's own addresses (both its LAN IP and its
  # tailnet IP terminate on the host itself, see tailscale.yml) to the
  # container's internal Samba port. NFS was tried too, but the kernel NFS
  # server (nfsd) requires mounting /proc/fs/nfsd, which unprivileged Incus
  # containers can't do (confirmed in practice: "mount: /proc/fs/nfsd:
  # permission denied") — Samba alone covers the actual use case, so NFS was
  # dropped rather than making this container privileged.
  device {
    name = "smb"
    type = "proxy"

    properties = {
      listen  = "tcp:0.0.0.0:445"
      connect = "tcp:127.0.0.1:445"
    }
  }
}
