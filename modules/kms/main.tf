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
# KMS Module — main.tf
#
# Resources:
#   - aws_kms_key / aws_kms_replica_key (conditional on var.create_replica)
#   - aws_kms_alias (one or more, from var.aliases)
#   - aws_kms_grant (from var.grants)
#
# Key policy is composed with data.aws_iam_policy_document so callers can
# layer statements without hand-writing JSON. Root account access is kept
# (required — otherwise the key can become unmanageable), and administration
# is delegated to var.key_administrators.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

#------------------------------------------------------------------------------
# Key policy
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "this" {
  count = var.create ? 1 : 0

  #checkov:skip=CKV_AWS_109:KMS key policy must use Resource=* (this key only); account root kms:* is required so IAM can govern the key
  #checkov:skip=CKV_AWS_111:KMS key policy Resource=* is an AWS constraint, not unconstrained IAM write access
  #checkov:skip=CKV_AWS_356:KMS key policies only allow Resource=*; it cannot target other resources
  # Never remove: prevents the key from becoming unmanageable.
  statement {
    sid       = "EnableRootAccountAccess"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }
  }

  dynamic "statement" {
    for_each = length(var.key_administrators) > 0 ? [1] : []

    content {
      sid = "KeyAdministration"
      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_administrators
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.key_users) > 0 ? [1] : []

    content {
      sid = "KeyUsage"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_users
      }
    }
  }

  # Allows key users to delegate use to integrated AWS services
  # (e.g. EBS, RDS) via grants, constrained to grants created *for* a service.
  dynamic "statement" {
    for_each = length(var.key_service_users) > 0 ? [1] : []

    content {
      sid = "KeyServiceUsage"
      actions = [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_service_users
      }

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  # Caller-supplied statements (rendered from var.source_policy_documents)
  # for service principals, cross-account access, ViaService conditions, etc.
  source_policy_documents   = var.source_policy_documents
  override_policy_documents = var.override_policy_documents
}

#------------------------------------------------------------------------------
# Key (primary or replica)
#------------------------------------------------------------------------------
resource "aws_kms_key" "this" {
  count = var.create && !var.create_replica ? 1 : 0

  description              = var.description
  key_usage                = var.key_usage
  customer_master_key_spec = var.key_spec
  policy                   = data.aws_iam_policy_document.this[0].json

  is_enabled              = var.is_enabled
  enable_key_rotation     = var.enable_key_rotation
  rotation_period_in_days = var.enable_key_rotation ? var.rotation_period_in_days : null
  multi_region            = var.multi_region

  deletion_window_in_days            = var.deletion_window_in_days
  bypass_policy_lockout_safety_check = var.bypass_policy_lockout_safety_check

  tags = local.tags
}

resource "aws_kms_replica_key" "this" {
  count = var.create && var.create_replica ? 1 : 0

  description     = var.description
  primary_key_arn = var.primary_key_arn
  policy          = data.aws_iam_policy_document.this[0].json

  enabled                            = var.is_enabled
  deletion_window_in_days            = var.deletion_window_in_days
  bypass_policy_lockout_safety_check = var.bypass_policy_lockout_safety_check

  tags = local.tags
}

#------------------------------------------------------------------------------
# Aliases
#------------------------------------------------------------------------------
resource "aws_kms_alias" "this" {
  for_each = var.create ? toset(var.aliases) : toset([])

  # Accept both "alias/name" and bare "name" inputs.
  name          = startswith(each.value, "alias/") ? each.value : "alias/${each.value}"
  target_key_id = local.key_id
}

#------------------------------------------------------------------------------
# Grants
#------------------------------------------------------------------------------
resource "aws_kms_grant" "this" {
  for_each = var.create ? var.grants : {}

  name              = coalesce(each.value.name, each.key)
  key_id            = local.key_id
  grantee_principal = each.value.grantee_principal
  operations        = each.value.operations

  retiring_principal    = each.value.retiring_principal
  grant_creation_tokens = each.value.grant_creation_tokens
  retire_on_delete      = each.value.retire_on_delete

  dynamic "constraints" {
    for_each = each.value.constraints != null ? [each.value.constraints] : []

    content {
      encryption_context_equals = constraints.value.encryption_context_equals
      encryption_context_subset = constraints.value.encryption_context_subset
    }
  }
}
