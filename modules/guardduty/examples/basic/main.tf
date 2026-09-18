# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# AWS GuardDuty Module - Basic Example
#
# Description:
#   Minimal, standalone-account deployment of the GuardDuty module. This
#   example intentionally relies on the module's secure defaults:
#     - Detector enabled with FIFTEEN_MINUTES publishing frequency.
#     - All core protection planes enabled (S3, EKS Audit Logs, EBS Malware
#       Protection, RDS Login Events, Lambda Network Logs, Runtime Monitoring).
#     - No Organizations integration, no findings export, no custom filters.
#
#   For multi-account (delegated administrator) and findings-export scenarios,
#   see the sibling examples (e.g. examples/organization, examples/export).
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# Prerequisites:
#   - AWS credentials for the target account (env vars, SSO, or shared
#     config profile).
#   - IAM permissions to create the GuardDuty service-linked role
#     (iam:CreateServiceLinkedRole for guardduty.amazonaws.com) — created
#     automatically on first detector activation.
#
# Cost Note:
#   GuardDuty pricing is usage-based (analyzed events/volume). The 30-day
#   free trial applies per account/region/feature; destroy this example
#   when finished evaluating to avoid charges.
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 7.0.0"
    }
  }
}

#------------------------------------------------------------------------------
# Provider
#
# Examples pin the region explicitly so `terraform plan` is reproducible for
# anyone cloning the repository. Override via the region variable or your
# environment as needed.
#------------------------------------------------------------------------------
variable "region" {
  description = "AWS Region in which to enable GuardDuty. GuardDuty is regional; deploy the module once per region you want monitored."
  type        = string
  default     = "eu-central-1"
}

provider "aws" {
  region = var.region
}

#------------------------------------------------------------------------------
# GuardDuty
#
# Only `tags` is passed explicitly; every other input uses the module's
# secure default (all protection planes enabled). To trim scope, override
# `detector_features` — e.g. disable RUNTIME_MONITORING if no container or
# EC2 runtime coverage is desired.
#------------------------------------------------------------------------------
module "guardduty" {
  source  = "../../"
  enabled = true

  # Demonstrates the caller-side tagging contract; merged with the module's
  # default tags in locals.tf.
  tags = {
    Environment = "sandbox"
    Project     = "guardduty-basic-example"
    ManagedBy   = "terraform"
  }
}

#------------------------------------------------------------------------------
# Outputs
#
# Re-export the identifiers a typical consumer needs next: the detector ID
# for EventBridge rules / member enrollment, and the ARN for IAM conditions.
#------------------------------------------------------------------------------
output "detector_id" {
  description = "GuardDuty detector ID for this region."
  value       = module.guardduty.detector_id
}

output "detector_arn" {
  description = "GuardDuty detector ARN, usable in IAM policy conditions."
  value       = module.guardduty.detector_arn
}

output "detector_feature_ids" {
  description = "Map of enabled protection-plane feature IDs, confirming which planes were activated."
  value       = module.guardduty.detector_feature_ids
}

output "effective_tags" {
  description = "The final merged tag set applied by the module."
  value       = module.guardduty.tags
}
