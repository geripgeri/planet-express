output "bucket_id" {
  description = "UUID of the created bucket"
  value       = var.create_bucket ? garage_bucket.main[0].id : null
}

output "bucket_global_alias" {
  description = "Global alias of the created bucket (its S3 bucket name)"
  value       = var.bucket_global_alias
}

output "access_key_id" {
  description = "Access key ID of the created key"
  value       = var.create_key ? garage_key.main[0].access_key_id : null
}

output "secret_access_key" {
  description = "Secret access key; only visible at creation time (sensitive)"
  value       = var.create_key ? garage_key.main[0].secret_access_key : null
  sensitive   = true
}
