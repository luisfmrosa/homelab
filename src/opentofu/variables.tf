variable "ssh_user" {
  description = "Username created on managed instances, with passwordless sudo and SSH key access, so Ansible can reach them."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key authorized for ssh_user (same key trusted on the homelab host itself, see references/INSTALL.md)."
  type        = string
}
