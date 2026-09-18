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
# KMS Module — variables.tf
#
# Conventions:
#   - Secure defaults: rotation on, lockout safety check on, 30-day deletion
#     window. Callers must opt out explicitly.
#   - All optional object attributes use optional() so callers specify only
#     what they need.
#   - validation blocks fail at plan time with actionable messages.
###############################################################################

#------------------------------------------------------------------------------
# Module behavior
#------------------------------------------------------------------------------
variable "create" {
  description = "Whether to create any resources in this module. Set to false to disable the module entirely (useful in conditional wrappers)."
  type        = bool
  default     = true
}

variable "create_replica" {
  description = "Whether to create a multi-Region replica key (aws_kms_replica_key) instead of a primary key. Requires primary_key_arn."
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# Key configuration
#------------------------------------------------------------------------------
variable "description" {
  description = "Description of the key, shown in the AWS console and API responses."
  type        = string
  default     = null
}

variable "key_usage" {
  description = "Intended use of the key. One of: ENCRYPT_DECRYPT, SIGN_VERIFY, GENERATE_VERIFY_MAC, KEY_AGREEMENT."
  type        = string
  default     = "ENCRYPT_DECRYPT"

  validation {
    condition = contains(
      ["ENCRYPT_DECRYPT", "SIGN_VERIFY", "GENERATE_VERIFY_MAC", "KEY_AGREEMENT"],
      var.key_usage
    )
    error_message = "key_usage must be one of: ENCRYPT_DECRYPT, SIGN_VERIFY, GENERATE_VERIFY_MAC, KEY_AGREEMENT."
  }
}

variable "key_spec" {
  description = "Key spec (customer_master_key_spec). Determines the key material type and supported algorithms."
  type        = string
  default     = "SYMMETRIC_DEFAULT"

  validation {
    condition = contains(
      [
        "SYMMETRIC_DEFAULT",
        "RSA_2048",
        "RSA_3072",
        "RSA_4096",
        "HMAC_224",
        "HMAC_256",
        "HMAC_384",
        "HMAC_512",
        "ECC_NIST_P256",
        "ECC_NIST_P384",
        "ECC_NIST_P521",
        "ECC_SECG_P256K1",
        "ML_DSA_44",
        "ML_DSA_65",
        "ML_DSA_87",
      ],
      var.key_spec
    )
    error_message = "key_spec must be a valid KMS key spec (e.g. SYMMETRIC_DEFAULT, RSA_2048, HMAC_256, ECC_NIST_P256)."
  }
}

variable "is_enabled" {
  description = "Whether the key is enabled for use."
  type        = bool
  default     = true
}

variable "enable_key_rotation" {
  description = "Whether automatic annual key rotation is enabled. Only valid for symmetric keys; disable deliberately if using asymmetric/HMAC keys."
  type        = bool
  default     = true
}

variable "rotation_period_in_days" {
  description = "Custom rotation period in days (90–2560). Only used when enable_key_rotation is true. Null uses the AWS default (365)."
  type        = number
  default     = null

  validation {
    condition = (
      var.rotation_period_in_days == null ||
      try(var.rotation_period_in_days >= 90 && var.rotation_period_in_days <= 2560, false)
    )
    error_message = "rotation_period_in_days must be between 90 and 2560, or null for the AWS default."
  }
}

variable "multi_region" {
  description = "Whether to create a multi-Region primary key. Cannot be changed after creation."
  type        = bool
  default     = false
}

variable "deletion_window_in_days" {
  description = "Waiting period (7–30 days) before the key is deleted after destruction is requested."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "bypass_policy_lockout_safety_check" {
  description = "Whether to bypass the key policy lockout safety check. Leave false unless you fully understand the risk of locking the key."
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# Replica key
#------------------------------------------------------------------------------
variable "primary_key_arn" {
  description = "ARN of the multi-Region primary key to replicate. Required when create_replica is true."
  type        = string
  default     = null

  validation {
    condition = (
      var.primary_key_arn == null ||
      can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/mrk-[a-f0-9]{32}$", var.primary_key_arn))
    )
    error_message = "primary_key_arn must be a multi-Region key ARN (arn:<partition>:kms:<region>:<account>:key/mrk-...)."
  }
}

#------------------------------------------------------------------------------
# Key policy
#------------------------------------------------------------------------------
variable "key_administrators" {
  description = "List of IAM principal ARNs granted key administration permissions (manage, not use)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.key_administrators : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:", arn))
    ])
    error_message = "Every entry in key_administrators must be an IAM principal ARN (arn:<partition>:iam::<account>:...)."
  }
}

variable "key_users" {
  description = "List of IAM principal ARNs granted cryptographic usage permissions (Encrypt, Decrypt, GenerateDataKey, ...)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.key_users : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:", arn))
    ])
    error_message = "Every entry in key_users must be an IAM principal ARN (arn:<partition>:iam::<account>:...)."
  }
}

variable "key_service_users" {
  description = "List of IAM principal ARNs allowed to create grants for AWS service integration (constrained by kms:GrantIsForAWSResource)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.key_service_users : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:", arn))
    ])
    error_message = "Every entry in key_service_users must be an IAM principal ARN (arn:<partition>:iam::<account>:...)."
  }
}

variable "source_policy_documents" {
  description = "List of IAM policy documents (JSON) merged into the key policy. Statements with non-blank SIDs override module statements with the same SID."
  type        = list(string)
  default     = []
}

variable "override_policy_documents" {
  description = "List of IAM policy documents (JSON) that override the merged policy. Applied after source_policy_documents; later documents win on SID conflict."
  type        = list(string)
  default     = []
}

#------------------------------------------------------------------------------
# Aliases
#------------------------------------------------------------------------------
variable "aliases" {
  description = "List of aliases to create for the key. Accepts either \"alias/name\" or bare \"name\"; names must not begin with \"aws/\" (reserved for AWS managed keys)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.aliases : can(regex("^(alias/)?[a-zA-Z0-9/_-]+$", a))
    ])
    error_message = "Aliases may contain only alphanumeric characters, forward slashes, underscores, and hyphens."
  }

  validation {
    condition = alltrue([
      for a in var.aliases : !startswith(trimprefix(a, "alias/"), "aws/")
    ])
    error_message = "The \"aws/\" alias prefix is reserved for AWS managed keys."
  }
}

#------------------------------------------------------------------------------
# Grants
#------------------------------------------------------------------------------
variable "grants" {
  description = <<-EOT
    Map of KMS grants to create, keyed by a stable identifier (used as the grant
    name when name is not set). Example:

      grants = {
        ebs = {
          grantee_principal = "arn:aws:iam::111122223333:role/service-role"
          operations        = ["Encrypt", "Decrypt", "DescribeKey"]
          constraints = {
            encryption_context_equals = { Department = "Finance" }
          }
        }
      }
  EOT
  type = map(object({
    name                  = optional(string)
    grantee_principal     = string
    operations            = list(string)
    retiring_principal    = optional(string)
    grant_creation_tokens = optional(list(string))
    retire_on_delete      = optional(bool, false)
    constraints = optional(object({
      encryption_context_equals = optional(map(string))
      encryption_context_subset = optional(map(string))
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for g in values(var.grants) : alltrue([
        for op in g.operations : contains(
          [
            "Decrypt",
            "Encrypt",
            "GenerateDataKey",
            "GenerateDataKeyWithoutPlaintext",
            "ReEncryptFrom",
            "ReEncryptTo",
            "Sign",
            "Verify",
            "GetPublicKey",
            "CreateGrant",
            "RetireGrant",
            "DescribeKey",
            "GenerateDataKeyPair",
            "GenerateDataKeyPairWithoutPlaintext",
            "GenerateMac",
            "VerifyMac",
          ],
          op
        )
      ])
    ])
    error_message = "Every grant operation must be a valid KMS grant operation (e.g. Encrypt, Decrypt, GenerateDataKey, DescribeKey)."
  }

  validation {
    condition = alltrue([
      for g in values(var.grants) : !(
        try(g.constraints.encryption_context_equals, null) != null &&
        try(g.constraints.encryption_context_subset, null) != null
      )
    ])
    error_message = "A grant constraint may set encryption_context_equals or encryption_context_subset, but not both."
  }
}

#------------------------------------------------------------------------------
# Tags
#------------------------------------------------------------------------------
variable "tags" {
  description = "Map of tags applied to all resources created by this module (merged with provider default_tags via locals)."
  type        = map(string)
  default     = {}
}
