variable "ssh_user" {
  description = "Username created on managed instances, with passwordless sudo and SSH key access, so Ansible can reach them."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key authorized for ssh_user (same key trusted on the homelab host itself, see references/INSTALL.md)."
  type        = string
}

# ---------------------------------------------------------------------------
# Values duplicated from src/ansible/group_vars/all/00-defaults.yml.
#
# OpenTofu and Ansible don't share a variable store: Ansible's group_vars are
# not visible here, and these are not visible there. Anything both tools need
# has to be stated twice, so the two copies can drift.
#
# That drift already bit once. dashboard_port was described as "the single
# source of truth" for the services dashboard's port, but the proxy device in
# headscale.tf had 8080 hardcoded. Changing dashboard_port to 8085 and
# re-running the playbook updated the *page's text* to say 8085 while the
# proxy device still forwarded 8080 — leaving the page confidently wrong,
# which is worse than leaving it stale.
#
# Declaring them here doesn't make them shared. It makes the duplication
# explicit and greppable, so the second half is visible rather than buried in
# a device block. CHANGING ONE MEANS CHANGING BOTH, AND RUNNING BOTH TOOLS.
# ---------------------------------------------------------------------------

variable "dashboard_port" {
  description = "Host-side port for the services dashboard. MUST match dashboard_port in src/ansible/group_vars/all/00-defaults.yml — that value is what the page prints, this one is what actually forwards."
  type        = number
  default     = 8080
}

variable "dashboard_internal_port" {
  description = "Port Caddy binds inside the headscale container for the dashboard. MUST match dashboard_internal_port in src/ansible/group_vars/all/00-defaults.yml. Deliberately not 8080: that's headscale's own API listener inside that container."
  type        = number
  default     = 8081
}
