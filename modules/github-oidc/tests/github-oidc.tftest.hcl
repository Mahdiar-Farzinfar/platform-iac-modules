# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# GitHub Actions OIDC Federation — Terraform Native Tests
#
# Strategy:
#   - Every run uses `command = plan` with a mocked AWS provider.
#   - Tests require no AWS credentials and create no real infrastructure.
#   - Assertions target configuration-derived values that are known at plan.
#   - Negative runs verify security-sensitive validation and preconditions.
#
# Requires: Terraform >= 1.7 (mock_provider support).
###############################################################################

mock_provider "aws" {}

# Baseline tags shared by every run. Individual runs override other inputs.
variables {
  tags = {
    Environment = "test"
    ManagedBy   = "manual" # module defaults must override this value
    CostCenter  = "cc-1234"
  }
}

# -----------------------------------------------------------------------------
# OIDC provider
# -----------------------------------------------------------------------------
run "creates_provider_with_secure_defaults" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "The GitHub Actions OIDC provider must be created by default."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com"
    error_message = "The OIDC provider must use GitHub's lowercase issuer URL."
  }

  assert {
    condition     = toset(aws_iam_openid_connect_provider.github[0].client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "The default OIDC audience must be sts.amazonaws.com."
  }

  assert {
    condition = (
      aws_iam_openid_connect_provider.github[0].tags["Name"] == "github-actions-oidc" &&
      aws_iam_openid_connect_provider.github[0].tags["ManagedBy"] == "terraform" &&
      aws_iam_openid_connect_provider.github[0].tags["Module"] == "github-oidc" &&
      aws_iam_openid_connect_provider.github[0].tags["Component"] == "ci-cd-identity" &&
      aws_iam_openid_connect_provider.github[0].tags["Environment"] == "test" &&
      aws_iam_openid_connect_provider.github[0].tags["CostCenter"] == "cc-1234"
    )
    error_message = "The OIDC provider must contain module identity tags and preserve non-conflicting caller tags."
  }

  assert {
    condition     = output.oidc_provider_url == "https://token.actions.githubusercontent.com"
    error_message = "oidc_provider_url must expose GitHub's issuer URL."
  }
}

run "supports_custom_audience" {
  command = plan

  variables {
    audiences = ["sts.amazonaws.com.cn"]

    roles = {
      deploy = {
        subjects = [
          "repo:octo-org/octo-repo:ref:refs/heads/main",
        ]
      }
    }
  }

  assert {
    condition     = toset(aws_iam_openid_connect_provider.github[0].client_id_list) == toset(["sts.amazonaws.com.cn"])
    error_message = "A caller-supplied audience must propagate to the OIDC provider."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.assume_role["deploy"].statement :
      anytrue([
        for condition in statement.condition :
        condition.test == "StringEquals" &&
        condition.variable == "token.actions.githubusercontent.com:aud" &&
        toset(condition.values) == toset(["sts.amazonaws.com.cn"])
      ])
    ])
    error_message = "A caller-supplied audience must be exact-matched in the role trust policy."
  }
}

# -----------------------------------------------------------------------------
# Exact subject trust
# -----------------------------------------------------------------------------
run "creates_role_with_exact_subject_defaults" {
  command = plan

  variables {
    roles = {
      deploy = {
        subjects = [
          "repo:octo-org/octo-repo:ref:refs/heads/main",
        ]

        tags = {
          Purpose = "deployment"
        }
      }
    }
  }

  assert {
    condition     = length(aws_iam_role.this) == 1
    error_message = "One configured role must create exactly one IAM role."
  }

  assert {
    condition = (
      aws_iam_role.this["deploy"].name == "deploy" &&
      aws_iam_role.this["deploy"].path == "/" &&
      aws_iam_role.this["deploy"].description == "Assumed by GitHub Actions using OpenID Connect." &&
      aws_iam_role.this["deploy"].max_session_duration == 3600 &&
      aws_iam_role.this["deploy"].permissions_boundary == null
    )
    error_message = "Omitted role attributes must resolve to their documented secure defaults."
  }

  assert {
    condition = (
      aws_iam_role.this["deploy"].tags["Name"] == "deploy" &&
      aws_iam_role.this["deploy"].tags["ManagedBy"] == "terraform" &&
      aws_iam_role.this["deploy"].tags["Module"] == "github-oidc" &&
      aws_iam_role.this["deploy"].tags["Purpose"] == "deployment" &&
      aws_iam_role.this["deploy"].tags["CostCenter"] == "cc-1234"
    )
    error_message = "Role tags must include module, role-specific, and non-conflicting caller tags."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.assume_role["deploy"].statement :
      statement.sid == "GitHubActionsExactSubjects" &&
      statement.effect == "Allow" &&
      toset(statement.actions) == toset(["sts:AssumeRoleWithWebIdentity"]) &&
      anytrue([
        for condition in statement.condition :
        condition.test == "StringEquals" &&
        condition.variable == "token.actions.githubusercontent.com:aud" &&
        toset(condition.values) == toset(["sts.amazonaws.com"])
      ]) &&
      anytrue([
        for condition in statement.condition :
        condition.test == "StringEquals" &&
        condition.variable == "token.actions.githubusercontent.com:sub" &&
        toset(condition.values) == toset([
          "repo:octo-org/octo-repo:ref:refs/heads/main",
        ])
      ])
    ])
    error_message = "Exact subjects must use an Allow statement with exact audience and subject matching."
  }

  assert {
    condition     = output.role_names["deploy"] == "deploy"
    error_message = "role_names must be keyed by the stable roles map key."
  }
}

# -----------------------------------------------------------------------------
# Explicit wildcard trust
# -----------------------------------------------------------------------------
run "separates_exact_and_pattern_subjects" {
  command = plan

  variables {
    roles = {
      release = {
        subjects = [
          "repo:octo-org@123456/octo-repo@456789:environment:production",
        ]

        subject_patterns = [
          "repo:octo-org@123456/octo-repo@456789:ref:refs/tags/release-*",
        ]
      }
    }
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.assume_role["release"].statement) == 2 &&
      toset(data.aws_iam_policy_document.assume_role["release"].statement[*].sid) == toset([
        "GitHubActionsExactSubjects",
        "GitHubActionsSubjectPatterns",
      ])
    )
    error_message = "Exact subjects and wildcard patterns must generate separate ORed policy statements."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.assume_role["release"].statement :
      statement.sid == "GitHubActionsExactSubjects" &&
      anytrue([
        for condition in statement.condition :
        condition.test == "StringEquals" &&
        condition.variable == "token.actions.githubusercontent.com:sub" &&
        toset(condition.values) == toset([
          "repo:octo-org@123456/octo-repo@456789:environment:production",
        ])
      ])
    ])
    error_message = "Immutable GitHub subjects must be accepted and exact-matched."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.assume_role["release"].statement :
      statement.sid == "GitHubActionsSubjectPatterns" &&
      anytrue([
        for condition in statement.condition :
        condition.test == "StringLike" &&
        condition.variable == "token.actions.githubusercontent.com:sub" &&
        toset(condition.values) == toset([
          "repo:octo-org@123456/octo-repo@456789:ref:refs/tags/release-*",
        ])
      ])
    ])
    error_message = "Explicit repository-scoped subject patterns must use StringLike."
  }
}

# -----------------------------------------------------------------------------
# Existing provider reuse
# -----------------------------------------------------------------------------
run "reuses_existing_provider" {
  command = plan

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"

    roles = {
      audit = {
        subjects = [
          "repo:octo-org/audit-repo:ref:refs/heads/main",
        ]
      }
    }
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "create_oidc_provider=false must suppress OIDC provider creation."
  }

  assert {
    condition     = output.oidc_provider_arn == var.oidc_provider_arn
    error_message = "oidc_provider_arn must expose the caller-supplied provider ARN when reusing a provider."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.assume_role["audit"].statement :
      anytrue([
        for principal in statement.principals :
        principal.type == "Federated" &&
        toset(principal.identifiers) == toset([var.oidc_provider_arn])
      ])
    ])
    error_message = "Role trust policies must reference the caller-supplied OIDC provider ARN."
  }
}

run "allows_provider_reuse_without_roles" {
  command = plan

  variables {
    create_oidc_provider = false
  }

  assert {
    condition = (
      length(aws_iam_openid_connect_provider.github) == 0 &&
      length(aws_iam_role.this) == 0 &&
      output.oidc_provider_arn == null
    )
    error_message = "A no-op configuration must be valid when provider creation is disabled and no roles are requested."
  }
}

# -----------------------------------------------------------------------------
# Role customization and permissions
# -----------------------------------------------------------------------------
run "configures_role_permissions_and_outputs" {
  command = plan

  variables {
    role_path = "/github-actions/"

    roles = {
      production = {
        name                     = "github-production-deploy"
        description              = "Deploys the production application from GitHub Actions."
        max_session_duration     = 7200
        permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform-boundary"

        subjects = [
          "repo:octo-org/octo-repo:environment:production",
        ]

        managed_policy_arns = [
          "arn:aws:iam::aws:policy/ReadOnlyAccess",
          "arn:aws:iam::123456789012:policy/deployment-access",
        ]

        inline_policies = {
          ReadArtifacts = jsonencode({
            Version = "2012-10-17"
            Statement = [{
              Sid      = "ReadArtifacts"
              Effect   = "Allow"
              Action   = ["s3:GetObject"]
              Resource = ["arn:aws:s3:::example-artifacts/*"]
            }]
          })
        }
      }
    }
  }

  assert {
    condition = (
      aws_iam_role.this["production"].name == "github-production-deploy" &&
      aws_iam_role.this["production"].path == "/github-actions/" &&
      aws_iam_role.this["production"].description == "Deploys the production application from GitHub Actions." &&
      aws_iam_role.this["production"].max_session_duration == 7200 &&
      aws_iam_role.this["production"].permissions_boundary == "arn:aws:iam::123456789012:policy/platform-boundary"
    )
    error_message = "Custom role identity, path, session duration, description, and boundary must propagate unchanged."
  }

  assert {
    condition = (
      length(aws_iam_role_policy_attachment.managed) == 2 &&
      toset([
        for attachment in values(aws_iam_role_policy_attachment.managed) :
        attachment.policy_arn
        ]) == toset([
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
        "arn:aws:iam::123456789012:policy/deployment-access",
      ]) &&
      alltrue([
        for attachment in values(aws_iam_role_policy_attachment.managed) :
        attachment.role == "github-production-deploy"
      ])
    )
    error_message = "Every configured managed policy must attach to the effective role name."
  }

  assert {
    condition = (
      length(aws_iam_role_policy.inline) == 1 &&
      aws_iam_role_policy.inline["production:ReadArtifacts"].name == "ReadArtifacts" &&
      aws_iam_role_policy.inline["production:ReadArtifacts"].role == "github-production-deploy" &&
      jsondecode(aws_iam_role_policy.inline["production:ReadArtifacts"].policy).Statement[0].Sid == "ReadArtifacts"
    )
    error_message = "Inline policies must use stable keys, effective role names, and valid canonical JSON."
  }

  assert {
    condition     = output.role_names["production"] == "github-production-deploy"
    error_message = "role_names must expose the effective custom IAM role name."
  }
}

# -----------------------------------------------------------------------------
# Input validation — negative tests
# -----------------------------------------------------------------------------
run "rejects_invalid_existing_provider_arn" {
  command = plan

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/example.com"
  }

  expect_failures = [var.oidc_provider_arn]
}

run "rejects_invalid_audience" {
  command = plan

  variables {
    audiences = ["sts.*.amazonaws.com"]
  }

  expect_failures = [var.audiences]
}

run "rejects_invalid_role_path" {
  command = plan

  variables {
    role_path = "github-actions"
  }

  expect_failures = [var.role_path]
}

run "rejects_reserved_tag_prefix" {
  command = plan

  variables {
    tags = {
      "aws:owner" = "platform"
    }
  }

  expect_failures = [var.tags]
}

run "rejects_role_without_subjects" {
  command = plan

  variables {
    roles = {
      deploy = {}
    }
  }

  expect_failures = [var.roles]
}

run "rejects_wildcard_in_exact_subject" {
  command = plan

  variables {
    roles = {
      deploy = {
        subjects = [
          "repo:octo-org/octo-repo:ref:refs/heads/*",
        ]
      }
    }
  }

  expect_failures = [var.roles]
}

run "rejects_wildcard_repository_identity" {
  command = plan

  variables {
    roles = {
      deploy = {
        subject_patterns = [
          "repo:octo-*/octo-repo:ref:refs/heads/main",
        ]
      }
    }
  }

  expect_failures = [var.roles]
}

run "rejects_duplicate_effective_role_names" {
  command = plan

  variables {
    roles = {
      first = {
        name     = "GitHubDeploy"
        subjects = ["repo:octo-org/first:ref:refs/heads/main"]
      }

      second = {
        name     = "githubdeploy"
        subjects = ["repo:octo-org/second:ref:refs/heads/main"]
      }
    }
  }

  expect_failures = [var.roles]
}

run "rejects_invalid_session_duration" {
  command = plan

  variables {
    roles = {
      deploy = {
        subjects             = ["repo:octo-org/octo-repo:ref:refs/heads/main"]
        max_session_duration = 1800
      }
    }
  }

  expect_failures = [var.roles]
}

run "rejects_invalid_managed_policy_arn" {
  command = plan

  variables {
    roles = {
      deploy = {
        subjects            = ["repo:octo-org/octo-repo:ref:refs/heads/main"]
        managed_policy_arns = ["ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.roles]
}

run "rejects_invalid_inline_policy_json" {
  command = plan

  variables {
    roles = {
      deploy = {
        subjects = ["repo:octo-org/octo-repo:ref:refs/heads/main"]

        inline_policies = {
          Broken = "not-json"
        }
      }
    }
  }

  expect_failures = [var.roles]
}

run "rejects_missing_reused_provider_arn_for_roles" {
  command = plan

  variables {
    create_oidc_provider = false

    roles = {
      deploy = {
        subjects = ["repo:octo-org/octo-repo:ref:refs/heads/main"]
      }
    }
  }

  expect_failures = [
    data.aws_iam_policy_document.assume_role["deploy"],
  ]
}
