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
# GitHub Actions OIDC Federation
#
# Creates or reuses the account-level GitHub Actions OIDC provider and creates
# IAM roles with repository-scoped web-identity trust policies.
#
# Exact subjects use StringEquals. Wildcard subjects require the explicit
# subject_patterns input and remain scoped to an exact repository identity by
# validation in variables.tf.
###############################################################################

# -----------------------------------------------------------------------------
# GitHub Actions OIDC provider
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = local.github_oidc_issuer_url
  client_id_list = local.client_id_list

  # AWS validates GitHub's certificate chain against its trusted CA library.
  # Omitting thumbprint_list avoids plan-time TLS lookups and certificate-
  # rotation drift.
  tags = merge(local.common_tags, {
    Name = "github-actions-oidc"
  })

  lifecycle {
    precondition {
      condition     = length(local.client_id_list) > 0
      error_message = "At least one OIDC audience must be configured."
    }

    precondition {
      condition = length(merge(
        local.common_tags,
        { Name = "github-actions-oidc" },
      )) <= 50
      error_message = "The GitHub OIDC provider cannot have more than 50 effective tags."
    }
  }
}

# -----------------------------------------------------------------------------
# IAM role trust policies
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_role" {
  for_each = local.roles

  # Exact subjects are the secure default and cannot contain IAM wildcard
  # characters. Examples include a specific branch, tag, pull request, or
  # protected GitHub environment.
  dynamic "statement" {
    for_each = length(each.value.subjects) > 0 ? [each.value.subjects] : []
    iterator = exact_subjects

    content {
      sid     = "GitHubActionsExactSubjects"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [local.oidc_provider_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.github_oidc_issuer_host}:aud"
        values   = local.client_id_list
      }

      condition {
        test     = "StringEquals"
        variable = "${local.github_oidc_issuer_host}:sub"
        values   = exact_subjects.value
      }
    }
  }

  # Patterns are intentionally separate from exact subjects so the two sets
  # are ORed as independent policy statements. Combining both condition types
  # in one statement would require a token to satisfy both.
  dynamic "statement" {
    for_each = length(each.value.subject_patterns) > 0 ? [each.value.subject_patterns] : []
    iterator = subject_patterns

    content {
      sid     = "GitHubActionsSubjectPatterns"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [local.oidc_provider_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.github_oidc_issuer_host}:aud"
        values   = local.client_id_list
      }

      condition {
        test     = "StringLike"
        variable = "${local.github_oidc_issuer_host}:sub"
        values   = subject_patterns.value
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.oidc_provider_arn != null
      error_message = "An existing oidc_provider_arn is required when create_oidc_provider is false and roles are configured."
    }

    precondition {
      condition     = length(each.value.subjects) + length(each.value.subject_patterns) > 0
      error_message = "Each IAM role must trust at least one exact subject or repository-scoped subject pattern."
    }
  }
}

# -----------------------------------------------------------------------------
# IAM roles
# -----------------------------------------------------------------------------
resource "aws_iam_role" "this" {
  for_each = local.roles

  name                 = each.value.name
  path                 = var.role_path
  description          = each.value.description
  assume_role_policy   = local.assume_role_policy_json[each.key]
  max_session_duration = each.value.max_session_duration
  permissions_boundary = each.value.permissions_boundary_arn

  depends_on = [data.aws_iam_policy_document.assume_role]

  tags = merge(local.common_tags, each.value.tags, {
    Name = each.value.name
  })

  lifecycle {
    precondition {
      condition = length(merge(
        local.common_tags,
        each.value.tags,
        { Name = each.value.name },
      )) <= 50
      error_message = "An IAM role cannot have more than 50 effective tags."
    }
  }
}

# -----------------------------------------------------------------------------
# Role permissions
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "managed" {
  for_each = local.managed_policy_attachments

  role       = aws_iam_role.this[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "inline" {
  for_each = local.inline_policies

  name   = each.value.policy_name
  role   = aws_iam_role.this[each.value.role_key].name
  policy = each.value.policy_json
}
