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
# GitHub Actions OIDC Federation — Local Values
#
# Centralizes fixed issuer details, deterministic collection normalization,
# effective role configuration, tagging, and resource iteration maps.
###############################################################################

locals {
  # GitHub's public Actions OIDC issuer is fixed and must remain lowercase.
  github_oidc_issuer_url  = "https://token.actions.githubusercontent.com"
  github_oidc_issuer_host = trimprefix(local.github_oidc_issuer_url, "https://")

  # Sets provide duplicate protection at the input boundary. Sorting after
  # conversion gives provider arguments and generated IAM policies stable
  # ordering across plans.
  client_id_list = sort(tolist(var.audiences))

  # Caller tags are merged first so module identity defaults win at this common
  # layer. Role-specific tags are merged later in main.tf for individual roles.
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "github-oidc"
    Component = "ci-cd-identity"
  })

  # Normalize optional role attributes once so resource blocks can consume a
  # predictable shape. Stable map keys are retained as Terraform addresses.
  roles = {
    for role_key, role in var.roles :
    role_key => {
      name                     = role.name != null ? role.name : role_key
      description              = role.description
      subjects                 = sort(tolist(role.subjects))
      subject_patterns         = sort(tolist(role.subject_patterns))
      max_session_duration     = role.max_session_duration
      permissions_boundary_arn = role.permissions_boundary_arn
      managed_policy_arns      = sort(tolist(role.managed_policy_arns))
      inline_policies          = role.inline_policies
      tags                     = role.tags
    }
  }

  # Use the ARN returned by the managed provider when this module creates it;
  # otherwise use the validated caller-supplied ARN. one() safely unwraps the
  # zero-or-one resource instance produced by count.
  oidc_provider_arn = var.create_oidc_provider ? one(
    aws_iam_openid_connect_provider.github[*].arn
  ) : var.oidc_provider_arn

  # Generate trust policies directly so native terraform tests receive a
  # deterministic JSON object instead of relying on a mocked data source.
  assume_role_policy_json = {
    for role_key, role in local.roles :
    role_key => jsonencode({
      Version = "2012-10-17"

      Statement = concat(
        length(role.subjects) > 0 ? [
          {
            Sid    = "GitHubActionsExactSubjects"
            Effect = "Allow"
            Action = ["sts:AssumeRoleWithWebIdentity"]

            Principal = {
              Federated = local.oidc_provider_arn == null ? [] : [
                local.oidc_provider_arn
              ]
            }

            Condition = {
              StringEquals = {
                "${local.github_oidc_issuer_host}:aud" = local.client_id_list
                "${local.github_oidc_issuer_host}:sub" = role.subjects
              }
            }
          }
        ] : [],

        length(role.subject_patterns) > 0 ? [
          {
            Sid    = "GitHubActionsSubjectPatterns"
            Effect = "Allow"
            Action = ["sts:AssumeRoleWithWebIdentity"]

            Principal = {
              Federated = local.oidc_provider_arn == null ? [] : [
                local.oidc_provider_arn
              ]
            }

            Condition = {
              StringEquals = {
                "${local.github_oidc_issuer_host}:aud" = local.client_id_list
              }

              StringLike = {
                "${local.github_oidc_issuer_host}:sub" = role.subject_patterns
              }
            }
          }
        ] : [],
      )
    })
  }

  # Flatten role-to-policy relationships into stable maps for resource
  # for_each. Hashing only the policy ARN keeps attachment keys compact while
  # preserving stable addresses when unrelated policies are added or removed.
  managed_policy_attachments = {
    for attachment in flatten([
      for role_key, role in local.roles : [
        for policy_arn in role.managed_policy_arns : {
          key        = "${role_key}:${sha1(policy_arn)}"
          role_key   = role_key
          policy_arn = policy_arn
        }
      ]
    ]) :
    attachment.key => attachment
  }

  # Inline policy names are unique within a role and cannot contain ':', so
  # role_key:policy_name is a readable, collision-free resource key. JSON is
  # canonicalized to avoid diffs caused only by whitespace or key ordering.
  inline_policies = {
    for policy in flatten([
      for role_key, role in local.roles : [
        for policy_name, policy_json in role.inline_policies : {
          key         = "${role_key}:${policy_name}"
          role_key    = role_key
          policy_name = policy_name
          policy_json = try(jsonencode(jsondecode(policy_json)), policy_json)
        }
      ]
    ]) :
    policy.key => policy
  }
}
