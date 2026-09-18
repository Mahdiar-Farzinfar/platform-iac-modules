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
# SCP Module — modules/scp
#
# Creates one AWS Organizations Service Control Policy (SCP) and attaches it
# to one or more organizational targets:
#   - Organization root IDs: r-*
#   - Organizational Unit IDs: ou-*
#   - AWS account IDs: 12-digit numeric identifiers
#
# The module is designed for reusable organization-wide guardrails and
# centralized baseline policies. Policy content is resolved by locals.tf
# through local.policy_content, allowing callers to provide either:
#   - A raw JSON policy document
#   - Structured policy statements supported by the module inputs
#
# Key contracts:
#   - var.create gates both the policy and all attachments. When false, the
#     module creates no resources while preserving the caller's configuration.
#   - var.skip_destroy controls whether the SCP is deleted when this module is
#     destroyed. When true, Terraform removes the managed resource from the
#     module lifecycle without deleting the policy in AWS; attachments are
#     still managed by the attachment resource lifecycle.
#   - Attachments are keyed by target ID, providing stable addressing when
#     targets are added or removed from var.target_ids. Changing one target
#     does not require re-attaching unrelated targets.
#
# Safety guarantees:
#   - AWS's 5120-character SCP document limit is enforced with a resource
#     precondition before apply.
#   - The policy document must be valid JSON.
#   - Each target ID is checked against the supported root, OU, and account
#     ID formats.
#   - Standard ownership tags are merged with caller-provided tags:
#       ManagedBy = terraform
#       Module    = scp
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#   terraform destroy
#
# Operational notes:
#   - Applying this module requires AWS Organizations permissions and may
#     affect governance across multiple accounts or organizational units.
#   - SCPs do not grant permissions; they define maximum permissions that can
#     be used by accounts, roles, and users within the organization.
#   - If skip_destroy is enabled, destroying the Terraform configuration does
#     not delete the SCP from AWS. Plan the policy's ownership and future
#     cleanup process accordingly.
#   - The policy and its attachments can affect production workloads. Review
#     the rendered policy and target list carefully before applying changes.
###############################################################################

# Creates a single Service Control Policy when var.create is enabled.
#
# The policy content is resolved in locals.tf. The lifecycle preconditions
# validate the document before Terraform submits it to AWS Organizations.
resource "aws_organizations_policy" "this" {
  count = var.create ? 1 : 0

  name        = var.name
  description = var.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.policy_content

  # When true, the SCP is retained in AWS when the module is removed from
  # the Terraform configuration or its resources are destroyed. This is
  # useful for shared baseline SCPs managed across state boundaries.
  skip_destroy = var.skip_destroy

  # Caller-provided tags are preserved and enriched with module ownership
  # metadata. If a caller supplies the same keys, merge ordering gives these
  # module-managed values precedence.
  tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Module    = "scp"
    }
  )

  lifecycle {
    # AWS imposes a hard maximum of 5120 characters for SCP documents.
    # This precondition fails during planning/apply instead of returning a
    # less actionable error from the AWS Organizations API.
    precondition {
      condition     = length(local.policy_content) <= 5120
      error_message = "SCP content for '${var.name}' is ${length(local.policy_content)} characters; the AWS limit is 5120."
    }

    # Ensures the resolved policy content is a syntactically valid JSON
    # document before it is submitted to AWS Organizations.
    precondition {
      condition     = can(jsondecode(local.policy_content))
      error_message = "SCP content for '${var.name}' is not valid JSON."
    }
  }
}

# Attaches the SCP to each configured organization target.
#
# for_each is keyed by target ID rather than list position. As a result,
# adding or removing one target produces a focused plan and does not cause
# unrelated targets to be re-attached.
resource "aws_organizations_policy_attachment" "this" {
  # No attachments are created when var.create is disabled. Converting the
  # target list to a set also prevents duplicate target IDs from producing
  # duplicate attachment instances.
  for_each = var.create ? toset(var.target_ids) : toset([])

  policy_id = aws_organizations_policy.this[0].id
  target_id = each.value

  lifecycle {
    # Validates supported AWS Organizations target ID formats:
    #   - Root:    r-<identifier>
    #   - OU:      ou-<parent>-<identifier>
    #   - Account: 12-digit account ID
    #
    # This validation is intentionally implemented as a resource precondition
    # so invalid targets fail before the attachment request is sent to AWS.
    precondition {
      condition     = can(regex("^(r-[a-z0-9]{4,32}|ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}|\\d{12})$", each.value))
      error_message = "Target '${each.value}' must be a root ID (r-*), OU ID (ou-*), or 12-digit account ID."
    }
  }
}
