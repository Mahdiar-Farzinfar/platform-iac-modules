# SPDX-License-Identifier: Apache-2.0
#
# Copyright 2026 Mahdiar Farzinfar
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################
# Backend Bootstrap — Input Variables
###############################################################################

# -----------------------------------------------------------------------------
# Naming & Tagging
# -----------------------------------------------------------------------------
variable "name_prefix" {
  description = <<-EOT
    Prefix used to derive resource names (state bucket, access-logs bucket,
    lock table). Must be globally-unique-friendly since S3 bucket names are
    global. Example: "acme-platform".
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,37}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-39 chars, lowercase alphanumeric and hyphens, and must not start or end with a hyphen (S3 naming rules)."
  }
}

variable "environment" {
  description = "Deployment environment identifier used in resource names and tags."
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["shared", "dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: shared, dev, staging, prod."
  }
}

variable "tags" {
  description = "Additional tags merged into all resources (on top of module-managed tags)."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Encryption
# -----------------------------------------------------------------------------
variable "kms_key_arn" {
  description = <<-EOT
    ARN of the customer-managed KMS key used to encrypt the state bucket and
    the DynamoDB lock table. The bucket policy denies uploads encrypted with
    any other key.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:\\d{12}:key/[a-f0-9-]{36}$", var.kms_key_arn))
    error_message = "kms_key_arn must be a full KMS key ARN (arn:aws:kms:<region>:<account>:key/<uuid>). Aliases are not accepted because the bucket policy requires the canonical key ARN."
  }
}

# -----------------------------------------------------------------------------
# State Bucket Lifecycle
# -----------------------------------------------------------------------------
variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent state object versions are expired."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "noncurrent_versions_to_retain" {
  description = "Number of newest noncurrent state versions always retained, regardless of age."
  type        = number
  default     = 10

  validation {
    condition     = var.noncurrent_versions_to_retain >= 1 && var.noncurrent_versions_to_retain <= 100
    error_message = "noncurrent_versions_to_retain must be between 1 and 100."
  }
}

# -----------------------------------------------------------------------------
# Access Logging
# -----------------------------------------------------------------------------
variable "enable_access_logging" {
  description = "Whether to create an access-logs bucket and enable S3 server access logging on the state bucket."
  type        = bool
  default     = true
}

variable "access_logs_retention_days" {
  description = "Retention period (in days) for S3 server access logs. Only used when enable_access_logging is true."
  type        = number
  default     = 365

  validation {
    condition     = var.access_logs_retention_days >= 1
    error_message = "access_logs_retention_days must be at least 1."
  }
}

# -----------------------------------------------------------------------------
# Safety Controls
# -----------------------------------------------------------------------------
variable "force_destroy" {
  description = <<-EOT
    Allow buckets to be destroyed even when they contain objects. Keep false
    in production; enable only for ephemeral/test bootstraps. Note that the
    state bucket also carries lifecycle.prevent_destroy as a second guard.
  EOT
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Enable DynamoDB deletion protection on the state-lock table."
  type        = bool
  default     = true
}
