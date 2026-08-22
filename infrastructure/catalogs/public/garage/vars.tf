variable "create_bucket" {
  description = "Create the garage_bucket resource"
  type        = bool
  default     = true
}

variable "bucket_global_alias" {
  description = "Global alias of the bucket (unique cluster-wide; used as the S3 bucket name)"
  type        = string
  default     = null
}

variable "create_key" {
  description = "Create the garage_key resource and bind it to a bucket"
  type        = bool
  default     = false
}

variable "key_name" {
  description = "Human-friendly name of the access key"
  type        = string
  default     = null
}
