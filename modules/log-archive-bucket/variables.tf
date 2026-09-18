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
# Log Archive Bucket Module — variables.tf
#
# Description:
#   Input variables for the log-archive-bucket module. Grouped by concern:
#   naming/tagging, safety, encryption, lifecycle, Object Lock (WORM),
#   access logging, and log-delivery policy.
#
# Conventions:
#   - Every variable declares an explicit type and description.
#   - Nullable optionals default to null; feature toggles default to the
#     safest posture (Object Lock off, force_destroy off).
#   - Validations fail fast at plan time instead of at the AWS API.
###############################################################################

# ----------------------------------------------------------------------------
# Naming & tagging
# ----------------------------------------------------------------------------
variable "bucket_name" {
  description = "Base name of the log archive bucket. Must satisfy S3 naming rules (3-63 chars, lowercase letters, digits, hyphens, dots)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters, start/end with a letter or digit, and contain only lowercase letters, digits, hyphens, and dots."
  }

  validation {
    condition     = !can(regex("[.]{2}|[.-]{2}|^xn--|-s3alias$", var.bucket_name))
    error_message = "bucket_name must not contain consecutive dots/dashes, start with 'xn--', or end with '-s3alias'."
  }
}

variable "tags" {
  description = "Tags applied to all resources created by this module (merged with module defaults in locals.tf)."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------------
# Safety
# ----------------------------------------------------------------------------
variable "force_destroy" {
  description = "Allow Terraform to delete the bucket even when it contains objects. Keep false for audit/log buckets; enable only in ephemeral environments."
  type        = bool
  default     = false
}

# ----------------------------------------------------------------------------
# Encryption
# ----------------------------------------------------------------------------
variable "kms_key_arn" {
  description = "ARN of a customer-managed KMS key for SSE-KMS. When null, SSE-S3 (AES256) is used and Bucket Keys are disabled."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:\\d{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a valid KMS key ARN (arn:aws:kms:<region>:<account-id>:key/<key-id>)."
  }
}

# ----------------------------------------------------------------------------
# Lifecycle & storage tiering
# ----------------------------------------------------------------------------
variable "lifecycle_prefix" {
  description = "Object key prefix the lifecycle rule applies to. Empty string applies the rule to the whole bucket."
  type        = string
  default     = ""
}

variable "transition_to_ia_days" {
  description = "Days after object creation before transition to STANDARD_IA. AWS requires a minimum of 30 days."
  type        = number
  default     = 30

  validation {
    condition     = var.transition_to_ia_days >= 30
    error_message = "transition_to_ia_days must be at least 30 (AWS minimum for STANDARD_IA)."
  }
}

variable "transition_to_glacier_days" {
  description = "Days after object creation before transition to GLACIER. Must be greater than transition_to_ia_days (recommended: +30 or more)."
  type        = number
  default     = 90

  validation {
    condition     = var.transition_to_glacier_days > 30
    error_message = "transition_to_glacier_days must be greater than 30 so it follows the STANDARD_IA transition."
  }
}

variable "transition_to_deep_archive_days" {
  description = "Days after object creation before transition to DEEP_ARCHIVE. Must be greater than transition_to_glacier_days."
  type        = number
  default     = 365

  validation {
    condition     = var.transition_to_deep_archive_days > 90
    error_message = "transition_to_deep_archive_days must be greater than 90 so it follows the GLACIER transition."
  }
}

variable "expiration_days" {
  description = "Days after which current object versions expire. Null disables expiration (retain indefinitely). When set, must exceed the last transition to avoid paying early-deletion fees."
  type        = number
  default     = null

  validation {
    condition     = var.expiration_days == null || try(var.expiration_days > 365, false)
    error_message = "expiration_days, when set, must be greater than 365 so objects are not deleted before reaching DEEP_ARCHIVE."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent (overwritten/deleted) object versions are permanently removed."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

# ----------------------------------------------------------------------------
# Object Lock (WORM) — immutable after bucket creation
# ----------------------------------------------------------------------------
variable "object_lock_enabled" {
  description = "Enable S3 Object Lock (WORM). Must be decided at bucket creation; it cannot be enabled or disabled afterwards."
  type        = bool
  default     = false
}

variable "object_lock_mode" {
  description = "Default Object Lock retention mode. GOVERNANCE allows privileged bypass; COMPLIANCE cannot be overridden by anyone, including the root user."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be either GOVERNANCE or COMPLIANCE."
  }
}

variable "object_lock_retention_days" {
  description = "Default retention period (days) applied to new objects when Object Lock is enabled."
  type        = number
  default     = 365

  validation {
    condition     = var.object_lock_retention_days >= 1
    error_message = "object_lock_retention_days must be at least 1."
  }
}

# ----------------------------------------------------------------------------
# Access logging & log delivery
# ----------------------------------------------------------------------------
variable "access_log_bucket" {
  description = "Name of a separate bucket to receive S3 server access logs for this bucket. Null disables access logging. Must not be this bucket itself (recursive logging)."
  type        = string
  default     = null
}

variable "log_delivery_service_principals" {
  description = "AWS service principals granted s3:PutObject via bucket policy, scoped to this account (e.g. [\"cloudtrail.amazonaws.com\", \"delivery.logs.amazonaws.com\"]). Empty list omits the statement."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.log_delivery_service_principals : can(regex("^[a-z0-9.-]+\\.amazonaws\\.com$", p))])
    error_message = "Each entry must be a valid AWS service principal ending in .amazonaws.com."
  }
}
