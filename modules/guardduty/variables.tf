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
# AWS GuardDuty Module - Input Variables
#
# Description:
#   Declares the input contract for the GuardDuty module. All complex inputs
#   use typed object() schemas with optional() attributes so callers only
#   override what differs from the secure defaults.
#
# Conventions:
#   - Enum-like inputs (frequencies, feature names, auto-enable modes) are
#     guarded by validation blocks to fail fast at plan time.
#   - Map keys act as stable state identifiers (feature name, set name,
#     filter name); renaming a key is a destroy/create operation.
###############################################################################

#------------------------------------------------------------------------------
# Module Gate
#------------------------------------------------------------------------------
variable "enabled" {
  description = "Master switch for the module. When false, no resources are created; useful for uniform multi-region/multi-account compositions."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Detector
#------------------------------------------------------------------------------
variable "finding_publishing_frequency" {
  description = "How often GuardDuty publishes updated findings to CloudWatch Events / EventBridge."
  type        = string
  default     = "FIFTEEN_MINUTES"

  validation {
    condition     = contains(["FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"], var.finding_publishing_frequency)
    error_message = "finding_publishing_frequency must be one of: FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS."
  }
}

#------------------------------------------------------------------------------
# Detector Features (Protection Planes)
#
# Map key = GuardDuty feature name. additional_configuration maps a
# sub-feature name (e.g. EKS_ADDON_MANAGEMENT, ECS_FARGATE_AGENT_MANAGEMENT,
# EC2_AGENT_MANAGEMENT) to its enabled state.
#------------------------------------------------------------------------------
variable "detector_features" {
  description = "Per-feature enablement for the detector. Keys are GuardDuty feature names; additional_configuration holds sub-feature toggles (agent/addon management)."
  type = map(object({
    enabled                  = bool
    additional_configuration = optional(map(bool), {})
  }))
  default = {
    S3_DATA_EVENTS         = { enabled = true }
    EKS_AUDIT_LOGS         = { enabled = true }
    EBS_MALWARE_PROTECTION = { enabled = true }
    RDS_LOGIN_EVENTS       = { enabled = true }
    LAMBDA_NETWORK_LOGS    = { enabled = true }
    RUNTIME_MONITORING     = { enabled = true }
  }

  validation {
    condition = alltrue([
      for name, _ in var.detector_features : contains([
        "S3_DATA_EVENTS",
        "EKS_AUDIT_LOGS",
        "EBS_MALWARE_PROTECTION",
        "RDS_LOGIN_EVENTS",
        "LAMBDA_NETWORK_LOGS",
        "RUNTIME_MONITORING",
        "EKS_RUNTIME_MONITORING",
      ], name)
    ])
    error_message = "detector_features keys must be valid GuardDuty feature names (S3_DATA_EVENTS, EKS_AUDIT_LOGS, EBS_MALWARE_PROTECTION, RDS_LOGIN_EVENTS, LAMBDA_NETWORK_LOGS, RUNTIME_MONITORING, EKS_RUNTIME_MONITORING)."
  }
}

#------------------------------------------------------------------------------
# Findings Export
#------------------------------------------------------------------------------
variable "publishing_destination" {
  description = "S3 export destination for findings. Bucket policy and KMS key policy must already grant guardduty.amazonaws.com. Set to null to disable export."
  type = object({
    bucket_arn  = string
    kms_key_arn = string
  })
  default = null

  validation {
    condition = var.publishing_destination == null || (
      can(regex("^arn:aws[a-zA-Z-]*:s3:::", var.publishing_destination.bucket_arn)) &&
      can(regex("^arn:aws[a-zA-Z-]*:kms:", var.publishing_destination.kms_key_arn))
    )
    error_message = "publishing_destination.bucket_arn must be an S3 bucket ARN and kms_key_arn must be a KMS key ARN."
  }
}

#------------------------------------------------------------------------------
# Trusted IP Sets
#------------------------------------------------------------------------------
variable "ipsets" {
  description = "Trusted IP sets keyed by set name. location is the S3 URI of the list file (e.g. https://s3.amazonaws.com/bucket/key or s3://bucket/key)."
  type = map(object({
    format   = string
    location = string
    activate = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, s in var.ipsets : contains(["TXT", "STIX", "OTX_CSV", "ALIEN_VAULT", "PROOF_POINT", "FIRE_EYE"], s.format)
    ])
    error_message = "ipsets format must be one of: TXT, STIX, OTX_CSV, ALIEN_VAULT, PROOF_POINT, FIRE_EYE."
  }
}

#------------------------------------------------------------------------------
# Threat Intel Sets
#------------------------------------------------------------------------------
variable "threat_intel_sets" {
  description = "Threat intelligence sets keyed by set name; same schema as ipsets."
  type = map(object({
    format   = string
    location = string
    activate = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, s in var.threat_intel_sets : contains(["TXT", "STIX", "OTX_CSV", "ALIEN_VAULT", "PROOF_POINT", "FIRE_EYE"], s.format)
    ])
    error_message = "threat_intel_sets format must be one of: TXT, STIX, OTX_CSV, ALIEN_VAULT, PROOF_POINT, FIRE_EYE."
  }
}

#------------------------------------------------------------------------------
# Finding Filters
#
# criteria is a list so a single filter can AND multiple criterion blocks.
# Numeric comparison attributes are strings per the AWS provider schema.
#------------------------------------------------------------------------------
variable "filters" {
  description = "Finding filters keyed by filter name. action is NOOP or ARCHIVE; rank (1-100) sets evaluation precedence, lower first."
  type = map(object({
    description = optional(string, "Managed by Terraform")
    action      = string
    rank        = number
    criteria = list(object({
      field                 = string
      equals                = optional(list(string))
      not_equals            = optional(list(string))
      greater_than          = optional(string)
      greater_than_or_equal = optional(string)
      less_than             = optional(string)
      less_than_or_equal    = optional(string)
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, f in var.filters : contains(["NOOP", "ARCHIVE"], f.action)
    ])
    error_message = "filters action must be either NOOP or ARCHIVE."
  }

  validation {
    condition = alltrue([
      for _, f in var.filters : f.rank >= 1 && f.rank <= 100
    ])
    error_message = "filters rank must be between 1 and 100."
  }

  validation {
    condition = alltrue([
      for _, f in var.filters : length(f.criteria) > 0
    ])
    error_message = "Each filter must define at least one criterion."
  }
}

#------------------------------------------------------------------------------
# Organization Integration
#
# delegate_admin applies only when running in the management account;
# manage_org_configuration applies only in the delegated admin account.
#------------------------------------------------------------------------------
variable "organization_admin" {
  description = "Organization role configuration. delegate_admin registers admin_account_id as the delegated administrator (management account only); manage_org_configuration controls org-wide auto-enrollment (delegated admin only)."
  type = object({
    delegate_admin           = optional(bool, false)
    admin_account_id         = optional(string, null)
    manage_org_configuration = optional(bool, false)
    auto_enable              = optional(string, "NEW")
  })
  default = {}

  validation {
    condition     = contains(["ALL", "NEW", "NONE"], var.organization_admin.auto_enable)
    error_message = "organization_admin.auto_enable must be one of: ALL, NEW, NONE."
  }

  validation {
    condition = (
      !var.organization_admin.delegate_admin ||
      can(regex("^[0-9]{12}$", var.organization_admin.admin_account_id))
    )
    error_message = "organization_admin.admin_account_id must be a 12-digit AWS account ID when delegate_admin is true."
  }
}

variable "organization_features" {
  description = "Org-wide auto-enable mode per GuardDuty feature (used only when manage_org_configuration is true). Keys are feature names; values are ALL, NEW, or NONE."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for _, mode in var.organization_features : contains(["ALL", "NEW", "NONE"], mode)
    ])
    error_message = "organization_features values must be one of: ALL, NEW, NONE."
  }
}

#------------------------------------------------------------------------------
# Tagging
#
# Merged in locals.tf (typically with module metadata) to produce local.tags
# consumed by all taggable resources.
#------------------------------------------------------------------------------
variable "tags" {
  description = "Additional tags applied to all taggable resources created by this module."
  type        = map(string)
  default     = {}
}
