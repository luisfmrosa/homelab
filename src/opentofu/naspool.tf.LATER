resource "incus_instance" "naspool" {
  name  = "naspool"
  image = "images:debian/12"

  config = {
    "boot.autostart"        = true
    "cloud-init.user-data"  = <<-EOT
      #cloud-config
      users:
        - name: ${var.ssh_user}
          groups: sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${var.ssh_public_key}
      ssh_pwauth: false
    EOT
  }

  device {
    name = "naspool"
    type = "disk"

    properties = {
      path   = "/naspool"
      source = "/naspool"
    }
  }
}
