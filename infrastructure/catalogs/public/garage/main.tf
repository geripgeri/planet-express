terraform {
  required_version = ">= 1.12.5"
  required_providers {
    garage = {
      # Fork of schwitzd/garage: SDK v2.3.0 and tolerant version detection
      # are required for Garage >= 2.2/2.5. See ADR-010 amendment 2026-11-28.
      source  = "geripgeri/garage"
      version = "1.2.3"
    }
  }
}

# One cohesive unit of Garage state-backend management: the bucket, its
# access key, and the permission binding between them. Units instantiate
# the parts they need via the create_bucket / create_key flags.

resource "garage_bucket" "main" {
  count        = var.create_bucket ? 1 : 0
  global_alias = var.bucket_global_alias
}

resource "garage_key" "main" {
  count = var.create_key ? 1 : 0
  name  = var.key_name
  permissions {
    read  = true
    write = true
  }
}

resource "garage_bucket_key" "main" {
  count         = var.create_key ? 1 : 0
  bucket_id     = garage_bucket.main[0].id
  access_key_id = garage_key.main[0].access_key_id
  read          = true
  write         = true
}
