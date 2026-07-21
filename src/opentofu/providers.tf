terraform {
  required_providers {
    incus = {
      source = "lxc/incus"
    }
  }
}

provider "incus" {
  default_remote = "homelab"
  config_dir     = "${pathexpand("~")}/AppData/Roaming/incus"
}
