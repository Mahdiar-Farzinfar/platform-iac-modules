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
# SCP Module — Input Variables
#
# These variables define the module's public contract. Policy content can be
# supplied in one of two ways, resolved by locals.tf into local.policy_content:
#   - var.policy_content : a raw, pre-rendered JSON policy document
#   - var.statements      : structured statements the module renders to JSON
#
# Exactly one source should be provided. Validation here catches obvious input
# errors early; the resource preconditions in main.tf enforce the AWS-level
# guarantees (5120-character limit and JSON validity) against the fully
# resolved document.
###############################################################################

variable "create" {
  description = <<-EOT
    Controls whether the SCP and its attachments are created. When false, the
    module manages no resources while preserving the caller's configuration.
  EOT
  type        = bool
  default     = true
}

variable "name" {
  description = "Name of the Service Control Policy. Must be unique within the organization."
  type        = string

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 128
    error_message = "The SCP name must be between 1 and 128 characters."
  }
}

variable "description" {
  description = "Human-readable description of the SCP's purpose."
  type        = string
  default     = "Managed by Terraform"

  validation {
    condition     = length(var.description) <= 512
    error_message = "The SCP description must be 512 characters or fewer."
  }
}

variable "policy_content" {
  description = <<-EOT
    Raw JSON policy document for the SCP. Mutually exclusive with
    var.statements. When set, it is used verbatim as the policy content.
    Leave null to render the document from var.statements instead.
  EOT
  type        = string
  default     = null

  validation {
    # Only validate JSON syntax when a raw document is supplied. The resolved
    # document's full validity is re-checked by the main.tf precondition.
    condition     = var.policy_content == null || can(jsondecode(var.policy_content))
    error_message = "var.policy_content must be a syntactically valid JSON document."
  }
}

variable "statements" {
  description = <<-EOT
    Structured policy statements rendered to a JSON document by locals.tf.
    Mutually exclusive with var.policy_content. Each statement follows the IAM
    policy statement shape; sid and condition are optional.
  EOT
  type = list(object({
    sid       = optional(string)
    effect    = string
    actions   = list(string)
    resources = list(string)
    condition = optional(map(map(list(string))), {})
  }))
  default = []

  validation {
    condition = alltrue([
      for s in var.statements : contains(["Allow", "Deny"], s.effect)
    ])
    error_message = "Each statement's effect must be either \"Allow\" or \"Deny\"."
  }

  validation {
    condition = alltrue([
      for s in var.statements : length(s.actions) > 0
    ])
    error_message = "Each statement must declare at least one action."
  }

  validation {
    condition = alltrue([
      for s in var.statements : length(s.resources) > 0
    ])
    error_message = "Each statement must declare at least one resource."
  }
}

variable "target_ids" {
  description = <<-EOT
    Organization targets the SCP is attached to. Accepts organization root IDs
    (r-*), organizational unit IDs (ou-*), and 12-digit AWS account IDs.
    Duplicate values are de-duplicated by the attachment resource.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.target_ids :
      can(regex("^(r-[a-z0-9]{4,32}|ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}|\\d{12})$", id))
    ])
    error_message = "Each target_id must be a root ID (r-*), OU ID (ou-*), or 12-digit account ID."
  }
}

variable "skip_destroy" {
  description = <<-EOT
    When true, the SCP is retained in AWS after the resource is removed from
    Terraform state. Useful for shared baseline SCPs whose lifecycle extends
    beyond a single module or state boundary.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = <<-EOT
    Tags applied to the SCP. Merged with module-managed tags (ManagedBy,
    Module), which take precedence on key collisions.
  EOT
  type        = map(string)
  default     = {}
}
