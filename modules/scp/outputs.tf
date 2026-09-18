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
# SCP Module — Outputs
#
# Exposes stable, consumer-facing attributes of the created Service Control
# Policy and its attachments. All outputs are null-safe: when var.create is
# false the policy resource has zero instances, so scalar outputs resolve to
# null and collection outputs resolve to empty rather than raising an index
# error.
#
# Design notes:
#   - The policy resource uses count, so it is addressed via [0] guarded by a
#     var.create check to avoid evaluating an out-of-range index.
#   - Attachment outputs derive from the for_each map, preserving the stable
#     target-ID keying used in main.tf.
#   - The rendered document is surfaced to aid debugging and downstream
#     composition, but callers must treat SCP content as sensitive governance
#     configuration.
###############################################################################

output "id" {
  description = "The unique identifier (ID) of the Service Control Policy, or null when create = false."
  value       = var.create ? aws_organizations_policy.this[0].id : null
}

output "arn" {
  description = "The Amazon Resource Name (ARN) of the Service Control Policy, or null when create = false."
  value       = var.create ? aws_organizations_policy.this[0].arn : null
}

output "name" {
  description = "The name of the Service Control Policy, or null when create = false."
  value       = var.create ? aws_organizations_policy.this[0].name : null
}

output "aws_managed" {
  description = "Whether the SCP is an AWS-managed policy. Always false for module-created policies, or null when create = false."
  value       = var.create ? false : null
}

output "policy_content" {
  description = <<-EOT
    The resolved policy document (JSON) that was submitted to AWS Organizations,
    whether provided as raw JSON via var.policy_content or rendered from
    var.statements. Exposed to support debugging and downstream composition.
  EOT
  value       = local.policy_content
}

output "target_ids" {
  description = "The set of organization target IDs (roots, OUs, or accounts) the SCP is attached to. Empty when create = false or no targets are configured."
  value       = var.create ? keys(aws_organizations_policy_attachment.this) : []
}

output "attachments" {
  description = <<-EOT
    Map of target ID to attachment details for each SCP attachment, keyed by
    the same stable target ID used in main.tf. Empty when create = false.
  EOT
  value = {
    for target_id, attachment in aws_organizations_policy_attachment.this :
    target_id => {
      policy_id = attachment.policy_id
      target_id = attachment.target_id
    }
  }
}
