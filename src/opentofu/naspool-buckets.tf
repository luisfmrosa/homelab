# BTRFS-backed Incus storage pool for S3-compatible storage buckets,
# entirely separate from the "default" pool and from naspool-samba's Samba
# share, even though both live on the same underlying /naspool BTRFS RAID1
# array. Points at a dedicated, empty subvolume (/naspool/incus-buckets)
# rather than the /naspool mount root itself, prepared by
# src/ansible/playbooks/naspool-buckets.yml — same "dedicated subvolume"
# pattern as the default pool's /var/lib/incus-pool (see incus.yml).
#
# Requires core.storage_buckets_address to be set on the Incus server
# (also done by incus.yml) — without it, buckets can be created but aren't
# reachable over S3 at all.
resource "incus_storage_pool" "naspool_buckets" {
  name   = "naspool-buckets"
  driver = "btrfs"

  config = {
    source = "/naspool/incus-buckets"
  }
}

resource "incus_storage_bucket" "naspool_buckets" {
  name = "incus-bucket"
  pool = incus_storage_pool.naspool_buckets.name
}

# Incus auto-creates an "admin" bucket key (role "admin") whenever a bucket
# is created, so this resource was imported from that key
# (`tofu import incus_storage_bucket_key.naspool_buckets_admin
# /naspool-buckets/incus-bucket/admin`) rather than created fresh —
# declaring a key named "admin" on `tofu apply` collides with Incus's own.
# `role`/`description` are set to match the auto-created key's actual
# values, so `tofu plan` reports no drift.
resource "incus_storage_bucket_key" "naspool_buckets_admin" {
  name           = "admin"
  pool           = incus_storage_bucket.naspool_buckets.pool
  storage_bucket = incus_storage_bucket.naspool_buckets.name
  role           = "admin"
  description    = "Admin user"
}

# access_key/secret_key are stored in plain text in Terraform state (a
# documented provider limitation) — treat the state file itself as a
# secret, same as this repo already does for the gitignored
# terraform.tfvars.
output "naspool_bucket_access_key" {
  value     = incus_storage_bucket_key.naspool_buckets_admin.access_key
  sensitive = true
}

output "naspool_bucket_secret_key" {
  value     = incus_storage_bucket_key.naspool_buckets_admin.secret_key
  sensitive = true
}
