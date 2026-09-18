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
# GitHub Actions OIDC Federation — Input Variables
###############################################################################

# -----------------------------------------------------------------------------
# OIDC provider
# -----------------------------------------------------------------------------
variable "create_oidc_provider" {
  description = "Whether to create the account-level GitHub Actions OIDC provider."
  type        = bool
  default     = true
  nullable    = false
}

variable "oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider. Required when create_oidc_provider is false and roles are configured."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.oidc_provider_arn == null ||
      can(regex(
        "^arn:[a-z0-9-]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$",
        var.oidc_provider_arn,
      ))
    )
    error_message = "oidc_provider_arn must be null or an AWS ARN ending in oidc-provider/token.actions.githubusercontent.com."
  }
}

variable "audiences" {
  description = "OIDC audiences trusted by the provider and IAM roles. Use sts.amazonaws.com for standard AWS partitions or the audience required by the target partition."
  type        = set(string)
  default     = ["sts.amazonaws.com"]
  nullable    = false

  validation {
    condition     = length(var.audiences) >= 1 && length(var.audiences) <= 100
    error_message = "audiences must contain between 1 and 100 unique values."
  }

  validation {
    condition = alltrue([
      for audience in var.audiences :
      length(audience) >= 1 &&
      length(audience) <= 255 &&
      !can(regex("[\\s*?]", audience))
    ])
    error_message = "Each audience must be 1-255 characters and must not contain whitespace or IAM wildcard characters."
  }
}

# -----------------------------------------------------------------------------
# IAM role defaults
# -----------------------------------------------------------------------------
variable "role_path" {
  description = "IAM path applied to every role created by this module."
  type        = string
  default     = "/"
  nullable    = false

  validation {
    condition = (
      length(var.role_path) <= 512 &&
      can(regex("^(/|/[!-~]+/)$", var.role_path))
    )
    error_message = "role_path must be '/', or begin and end with '/' using printable non-space ASCII characters, and must not exceed 512 characters."
  }
}

variable "tags" {
  description = "Tags applied to the GitHub OIDC provider and all IAM roles. Role-specific tags are merged on top; module-managed Name tags take precedence."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition     = length(var.tags) <= 50
    error_message = "tags cannot contain more than 50 entries."
  }

  validation {
    condition = alltrue([
      for tag_key, tag_value in var.tags :
      length(tag_key) >= 1 &&
      length(tag_key) <= 128 &&
      try(length(tag_value) <= 256, false) &&
      !startswith(lower(tag_key), "aws:")
    ])
    error_message = "Tag keys must be 1-128 characters and must not start with 'aws:'; tag values must be non-null and at most 256 characters."
  }
}

# -----------------------------------------------------------------------------
# GitHub Actions IAM roles
# -----------------------------------------------------------------------------
variable "roles" {
  description = <<-EOT
    IAM roles trusted by GitHub Actions, keyed by stable Terraform identifiers.
    The map key becomes the IAM role name when name is omitted.

    subjects contains exact OIDC `sub` claim values. Exact subjects cannot
    contain IAM wildcard characters, but may use GitHub's standard, immutable,
    or customized subject formats.

    subject_patterns is an explicit opt-in to StringLike matching. Every
    pattern must remain scoped to an exact owner and repository using:
      repo:<owner>/<repository>:<pattern>

    Examples:
      repo:octo-org/octo-repo:ref:refs/heads/main
      repo:octo-org/octo-repo:environment:production
      repo:octo-org@123456/octo-repo@456789:ref:refs/heads/main
      repo:octo-org/octo-repo:ref:refs/tags/release-*

    managed_policy_arns and inline_policies define the role's permissions.
    Callers remain responsible for granting least privilege.
  EOT

  type = map(object({
    name                     = optional(string)
    description              = optional(string, "Assumed by GitHub Actions using OpenID Connect.")
    subjects                 = optional(set(string), [])
    subject_patterns         = optional(set(string), [])
    max_session_duration     = optional(number, 3600)
    permissions_boundary_arn = optional(string)
    managed_policy_arns      = optional(set(string), [])
    inline_policies          = optional(map(string), {})
    tags                     = optional(map(string), {})
  }))

  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for role_key in keys(var.roles) :
      can(regex("^[A-Za-z0-9_-]{1,64}$", role_key))
    ])
    error_message = "Each roles map key must be 1-64 characters and contain only letters, numbers, underscores, or hyphens."
  }

  validation {
    condition = alltrue([
      for role_key, role in var.roles :
      can(regex(
        "^[A-Za-z0-9_+=,.@-]{1,64}$",
        role.name != null ? role.name : role_key,
      ))
    ])
    error_message = "Each effective IAM role name must be 1-64 characters and contain only letters, numbers, or _+=,.@-."
  }

  validation {
    condition = length(distinct([
      for role_key, role in var.roles :
      lower(role.name != null ? role.name : role_key)
    ])) == length(var.roles)
    error_message = "Effective IAM role names must be unique, ignoring case."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      length(trimspace(role.description)) >= 1 &&
      length(role.description) <= 1000 &&
      trimspace(role.description) == role.description &&
      !can(regex("[\\r\\n\\t]", role.description))
    ])
    error_message = "Role descriptions must be 1-1000 characters, must not have surrounding whitespace, and must not contain tabs or newlines."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      role.max_session_duration >= 3600 &&
      role.max_session_duration <= 43200 &&
      floor(role.max_session_duration) == role.max_session_duration
    ])
    error_message = "max_session_duration must be a whole number between 3600 and 43200 seconds."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      length(role.subjects) + length(role.subject_patterns) >= 1
    ])
    error_message = "Every role must define at least one exact subject or repository-scoped subject pattern."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.roles) : [
        for subject in role.subjects :
        length(subject) >= 1 &&
        !can(regex("[\\s*?]", subject))
      ]
    ]))
    error_message = "Exact subjects must be non-empty and must not contain whitespace, '*' or '?'. Use subject_patterns for wildcard matching."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.roles) : [
        for subject_pattern in role.subject_patterns :
        can(regex(
          "^repo:[^:/?*\\s]+/[^:/?*\\s]+:.+$",
          subject_pattern,
        )) &&
        can(regex("[*?]", subject_pattern)) &&
        !can(regex("\\s", subject_pattern))
      ]
    ]))
    error_message = "Each subject pattern must contain a wildcard and match repo:<exact-owner>/<exact-repository>:<pattern>; wildcards are not allowed in owner or repository names."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      role.permissions_boundary_arn == null ||
      can(regex(
        "^arn:[^:\\s]+:iam::(aws|[0-9]{12}):policy/[^\\s]+$",
        role.permissions_boundary_arn,
      ))
    ])
    error_message = "Each permissions_boundary_arn must be null or a valid IAM managed-policy ARN."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.roles) : [
        for policy_arn in role.managed_policy_arns :
        can(regex(
          "^arn:[^:\\s]+:iam::(aws|[0-9]{12}):policy/[^\\s]+$",
          policy_arn,
        ))
      ]
    ]))
    error_message = "Every managed_policy_arns entry must be a valid IAM managed-policy ARN."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      length(role.managed_policy_arns) <= 20 &&
      length(role.inline_policies) <= 10
    ])
    error_message = "A role can define at most 20 managed policy attachments and 10 inline policies."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.roles) : [
        for policy_name, policy_json in role.inline_policies :
        can(regex("^[A-Za-z0-9_+=,.@-]{1,128}$", policy_name)) &&
        can(contains(keys(jsondecode(policy_json)), "Statement"))
      ]
    ]))
    error_message = "Inline policy names must use supported IAM characters; every policy value must be a valid JSON object containing Statement."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      sum(concat(
        [0],
        [
          for policy_json in values(role.inline_policies) :
          try(length(jsonencode(jsondecode(policy_json))), 10241)
        ],
      )) <= 10240
    ])
    error_message = "The normalized aggregate size of inline policies for a role must not exceed 10,240 characters."
  }

  validation {
    condition = alltrue([
      for role in values(var.roles) :
      length(role.tags) <= 50
    ])
    error_message = "Role-specific tags cannot contain more than 50 entries."
  }

  validation {
    condition = alltrue(flatten([
      for role in values(var.roles) : [
        for tag_key, tag_value in role.tags :
        length(tag_key) >= 1 &&
        length(tag_key) <= 128 &&
        try(length(tag_value) <= 256, false) &&
        !startswith(lower(tag_key), "aws:")
      ]
    ]))
    error_message = "Role tag keys must be 1-128 characters and must not start with 'aws:'; values must be non-null and at most 256 characters."
  }
}
