# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# Backend Bootstrap — Basic Example
#
# Self-contained example that provisions:
#   - A customer-managed KMS key (the module requires a full key ARN)
#   - The backend-bootstrap module with sensible defaults
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# NOTE: The module applies with LOCAL state by design (chicken-and-egg).
# After apply, use the `backend_hcl_snippet` output to configure consuming
# stacks, then optionally migrate this stack's own state via
# `terraform init -migrate-state`.
#
# NOTE: The state bucket and lock table carry `lifecycle.prevent_destroy`.
# `terraform destroy` on this example will fail by design; removing the
# bootstrap requires editing the module source deliberately.
###############################################################################

terraform {
  # Match the module's constraints (see ../../versions.tf).
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0, < 7.0.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Inputs
# -----------------------------------------------------------------------------
variable "region" {
  description = "AWS region to deploy the remote-state infrastructure into."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Globally-unique-friendly prefix for bucket and table names."
  type        = string
  default     = "acme-platform"
}

# -----------------------------------------------------------------------------
# Provider
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Example   = "backend-bootstrap-basic"
    }
  }
}

# -----------------------------------------------------------------------------
# KMS key for state encryption
#
# The module's bucket policy denies writes encrypted with any other key, and
# its `kms_key_arn` validation requires the canonical key ARN (no aliases).
# -----------------------------------------------------------------------------
resource "aws_kms_key" "terraform_state" {
  description             = "Encrypts Terraform remote state (S3) and the lock table (DynamoDB)."
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${var.name_prefix}-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

# -----------------------------------------------------------------------------
# Backend bootstrap
# -----------------------------------------------------------------------------
module "backend_bootstrap" {
  source = "../.."

  # --- Required ---
  name_prefix = var.name_prefix
  kms_key_arn = aws_kms_key.terraform_state.arn

  # --- Naming & tagging ---
  environment = "shared"
  tags = {
    Owner      = "platform-team"
    CostCenter = "infrastructure"
  }

  # --- Defaults shown explicitly for documentation purposes ---
  enable_access_logging              = true
  access_logs_retention_days         = 365
  noncurrent_version_expiration_days = 90
  noncurrent_versions_to_retain      = 10

  # --- Safety controls: keep production-safe defaults ---
  force_destroy              = false
  enable_deletion_protection = true
}

# -----------------------------------------------------------------------------
# Outputs — re-export what consumers need to configure their backend
# -----------------------------------------------------------------------------
output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state."
  value       = module.backend_bootstrap.state_bucket_name
}

output "lock_table_name" {
  description = "Name of the DynamoDB table used for state locking."
  value       = module.backend_bootstrap.lock_table_name
}

output "kms_key_arn" {
  description = "KMS key ARN used to encrypt state objects and the lock table."
  value       = module.backend_bootstrap.kms_key_arn
}

output "backend_config" {
  description = "Backend settings map for `terraform init -backend-config` or automation."
  value       = module.backend_bootstrap.backend_config
}

output "backend_hcl_snippet" {
  description = "Copy-paste `backend \"s3\"` block for consuming Terraform projects."
  value       = module.backend_bootstrap.backend_hcl_snippet
}
