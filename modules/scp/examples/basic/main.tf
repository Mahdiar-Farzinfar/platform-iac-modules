# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# SCP Module — Basic Example
#
# Demonstrates the minimum viable configuration for deploying a Service
# Control Policy using the module's structured statement interface (HCL
# objects rendered to JSON by locals.tf in the parent module).
#
# What this example creates:
#   - One SCP containing two baseline guardrail statements.
#   - An attachment of that SCP to the organization root, which makes the
#     policy effective across every account and OU in the organization.
#
# Statements deployed:
#   DenyLeaveOrganization — Prevents any principal from removing an AWS
#     account from the organization. This is a near-universal guardrail
#     that protects the management boundary even if a member account is
#     compromised.
#   DenyDisableCloudTrail — Prevents StopLogging, DeleteTrail, and
#     UpdateTrail from reaching CloudTrail resources. Preserves the audit
#     record required by most compliance frameworks.
#
# Design choices:
#   - The organization root ID is resolved through the
#     aws_organizations_organization data source instead of being
#     hard-coded. This makes the example portable across organizations and
#     removes a manual lookup step during onboarding.
#   - var.tags contains only logical, environment-level metadata. Module-
#     managed ownership tags (ManagedBy = terraform, Module = scp) are
#     merged automatically by the parent module.
#   - skip_destroy is intentionally left at its default (false) for this
#     example so that terraform destroy performs a clean teardown. In
#     production, set skip_destroy = true for any SCP that must survive
#     beyond the lifecycle of a single Terraform state.
#
# Prerequisites:
#   - An active AWS Organizations management account with SCPs feature set
#     enabled (aws_organizations_organization.feature_set = ALL).
#   - AWS credentials with organizations:Describe*, organizations:Create*,
#     organizations:Attach*, and organizations:Detach* permissions.
#   - Terraform >= 1.5 and the hashicorp/aws provider >= 5.0.
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#   terraform destroy
#
# Outputs are declared in outputs.tf in this directory.
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
# Resolves organization metadata at plan time. roots[0].id is the root ID
# (r-*) used as the attachment target below.
data "aws_organizations_organization" "this" {}

# ---------------------------------------------------------------------------
# Module
# ---------------------------------------------------------------------------
module "baseline_guardrails" {
  source = "../../"

  name        = "baseline-guardrails"
  description = "Organization-wide baseline guardrails: deny leaving org and disabling CloudTrail."

  # Two guardrail statements rendered to a policy document by the module.
  # Each object maps directly to an IAM policy statement; sid and condition
  # are optional and are omitted here for brevity.
  statements = [
    {
      sid       = "DenyLeaveOrganization"
      effect    = "Deny"
      actions   = ["organizations:LeaveOrganization"]
      resources = ["*"]
    },
    {
      sid    = "DenyDisableCloudTrail"
      effect = "Deny"
      actions = [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
      ]
      resources = ["*"]
    },
  ]

  # Attach the SCP to the organization root so it applies to every account
  # and OU in the organization. For a narrower blast radius, replace this
  # with one or more OU IDs (ou-*) or 12-digit account IDs.
  target_ids = [data.aws_organizations_organization.this.roots[0].id]

  tags = {
    Environment = "all"
    Purpose     = "guardrail"
  }
}
