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
# AWS CloudTrail Module — Input Variables
#
# Variables are grouped by concern:
#   1. General         — naming, tagging.
#   2. KMS             — customer managed key creation or BYOK (bring your own key).
#   3. S3              — bucket creation, lifecycle, and retention policies.
#   4. CloudWatch Logs — real-time log delivery configuration.
#   5. Trail           — core CloudTrail engine behavior and event filtering.
#
# Conventions:
#   - Every variable declares an explicit `type` and `description`.
#   - Secure-by-default values; overrides require deliberate action.
#   - `validation` blocks fail fast at plan time with actionable messages.
###############################################################################

#------------------------------------------------------------------------------
# 1. General
#------------------------------------------------------------------------------
variable "trail_name" {
  description = "Name of the CloudTrail trail. Must be 3-128 characters: letters, digits, hyphens, underscores, or periods."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$", var.trail_name))
    error_message = "The `trail_name` must be 3-128 characters, start with an alphanumeric character, and contain only letters, digits, hyphens, underscores, or periods."
  }
}

variable "tags" {
  description = "A map of tags applied to all resources created by this module. Merged with module-managed tags in `locals.tf`."
  type        = map(string)
  default     = {}
}

#------------------------------------------------------------------------------
# 2. KMS
#------------------------------------------------------------------------------
variable "create_kms_key" {
  description = "Whether to create a dedicated KMS customer managed key (CMK) with automatic rotation for encrypting CloudTrail logs. Set to `false` to supply an existing key via `kms_key_arn` or to fall back to SSE-S3 (AES256)."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "ARN of an existing KMS key to use when `create_kms_key = false`. Leave `null` to use SSE-S3 (AES256) for the bucket and no CMK for the trail."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:\\d{12}:key/[a-f0-9-]{36}$", var.kms_key_arn))
    error_message = "The `kms_key_arn` must be a valid KMS key ARN (e.g. arn:aws:kms:us-east-1:123456789012:key/<uuid>)."
  }
}

variable "kms_key_deletion_window" {
  description = "Waiting period (in days) before the KMS key is deleted after `terraform destroy`. AWS allows 7-30 days; longer windows provide a safety net against accidental deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window >= 7 && var.kms_key_deletion_window <= 30
    error_message = "The `kms_key_deletion_window` must be between 7 and 30 days (AWS constraint)."
  }
}

#------------------------------------------------------------------------------
# 2. SNS Notifications
#------------------------------------------------------------------------------
variable "enable_sns_notifications" {
  description = "Whether to create an SNS topic and configure CloudTrail to publish delivery notifications to it."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# 3. S3
#------------------------------------------------------------------------------
variable "create_s3_bucket" {
  description = "Whether to create and manage the S3 log destination bucket (versioning, SSE, public access block, lifecycle, bucket policy). Set to `false` to deliver logs to an existing bucket via `s3_bucket_name`."
  type        = bool
  default     = true
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket. When `create_s3_bucket = true` and this is `null`, a deterministic name is derived in `locals.tf`. When `create_s3_bucket = false`, this is REQUIRED and must reference an existing bucket with a valid CloudTrail bucket policy."
  type        = string
  default     = null

  validation {
    condition     = var.s3_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_bucket_name))
    error_message = "The `s3_bucket_name` must be 3-63 characters, lowercase letters, digits, hyphens, or periods, and must start/end with a letter or digit."
  }
}

variable "s3_key_prefix" {
  description = "Prefix (folder path) under which CloudTrail delivers log files within the bucket. Useful for multi-trail or organization-wide buckets."
  type        = string
  default     = "cloudtrail"

  validation {
    condition     = !startswith(var.s3_key_prefix, "/") && !endswith(var.s3_key_prefix, "/")
    error_message = "The `s3_key_prefix` must not start or end with a slash (`/`)."
  }
}

variable "s3_force_destroy" {
  description = "Allow Terraform to destroy the bucket even if it contains objects. DANGER: enables irreversible deletion of audit logs — keep `false` in production."
  type        = bool
  default     = false
}

variable "s3_lifecycle_enabled" {
  description = "Whether to enable the S3 lifecycle policy that transitions logs to STANDARD_IA and GLACIER, then expires them. Disable if retention is governed externally (e.g. Object Lock or compliance tooling)."
  type        = bool
  default     = true
}

variable "s3_transition_to_ia_days" {
  description = "Number of days after object creation before transitioning logs to STANDARD_IA. AWS requires a minimum of 30 days."
  type        = number
  default     = 30

  validation {
    condition     = var.s3_transition_to_ia_days >= 30
    error_message = "The `s3_transition_to_ia_days` must be at least 30 days (AWS constraint for STANDARD_IA)."
  }
}

variable "s3_transition_to_glacier_days" {
  description = "Number of days after object creation before transitioning logs to GLACIER. Must be greater than `s3_transition_to_ia_days`."
  type        = number
  default     = 90
}

variable "s3_expiration_days" {
  description = "Number of days after object creation before logs are permanently expired. Align with your compliance retention requirements (e.g. 365 for SOC 2, 2555 for 7-year regulatory retention). Must be greater than `s3_transition_to_glacier_days`."
  type        = number
  default     = 365
}

#------------------------------------------------------------------------------
# 4. CloudWatch Logs
#------------------------------------------------------------------------------
variable "enable_cloudwatch_logs" {
  description = "Whether to stream CloudTrail events to a CloudWatch Log Group for real-time monitoring, metric filters, and alerting."
  type        = bool
  default     = true
}

variable "cloudwatch_log_group_name" {
  description = "Custom name for the CloudWatch Log Group. When `null`, a default name is derived in `locals.tf` (e.g. `/aws/cloudtrail/<name>`)."
  type        = string
  default     = null
}

variable "cloudwatch_logs_retention_days" {
  description = "Retention period (in days) for the CloudWatch Log Group. Must be one of the values supported by AWS."
  type        = number
  default     = 365

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.cloudwatch_logs_retention_days
    )
    error_message = "The `cloudwatch_logs_retention_days` must be one of the AWS-supported values: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

#------------------------------------------------------------------------------
# 5. Trail
#------------------------------------------------------------------------------
variable "enable_logging" {
  description = "Whether the trail actively records events. Setting `false` suspends recording without destroying the trail (useful for break-glass scenarios)."
  type        = bool
  default     = true
}

variable "is_multi_region_trail" {
  description = "Whether the trail captures events from all AWS regions. Strongly recommended (`true`) per CIS AWS Foundations Benchmark 3.1."
  type        = bool
  default     = true
}

variable "include_global_service_events" {
  description = "Whether to include events from global services such as IAM, STS, and CloudFront."
  type        = bool
  default     = true
}

variable "event_selectors" {
  description = <<-EOT
    List of basic event selectors for filtering management and data events.
    Mutually exclusive with `advanced_event_selectors`.

    Example:
      [{
        read_write_type           = "All"
        include_management_events = true
        data_resources = [{
          type   = "AWS::S3::Object"
          values = ["arn:aws:s3"]
        }]
      }]
  EOT
  type = list(object({
    read_write_type           = optional(string, "All")
    include_management_events = optional(bool, true)
    data_resources = optional(list(object({
      type   = string
      values = list(string)
    })), [])
  }))
  default = []

  validation {
    condition = alltrue([
      for es in var.event_selectors : contains(["ReadOnly", "WriteOnly", "All"], es.read_write_type)
    ])
    error_message = "Each `read_write_type` must be one of: ReadOnly, WriteOnly, All."
  }
}

variable "advanced_event_selectors" {
  description = <<-EOT
    List of advanced event selectors for fine-
grained filtering (e.g., filtering on `eventName`, `eventCategory`, `resources.ARN`).
    Mutually exclusive with `event_selectors`.

    Example:
      [{
        name = "Log S3 Data Events"
        field_selectors = [{
          field  = "eventCategory"
          equals = ["Data"]
        }]
      }]
  EOT
  type = list(object({
    name = string
    field_selectors = list(object({
      field           = string
      equals          = optional(list(string))
      not_equals      = optional(list(string))
      starts_with     = optional(list(string))
      not_starts_with = optional(list(string))
      ends_with       = optional(list(string))
      not_ends_with   = optional(list(string))
    }))
  }))
  default = []
}

variable "insight_selectors" {
  description = "A list of CloudTrail Insight types to enable. Supported values: `ApiCallRateInsight`, `ApiErrorRateInsight`."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for i in var.insight_selectors : contains(["ApiCallRateInsight", "ApiErrorRateInsight"], i)
    ])
    error_message = "Supported insight selectors are `ApiCallRateInsight` and `ApiErrorRateInsight`."
  }
}
