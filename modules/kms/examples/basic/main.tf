# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# KMS Module — examples/basic
#
# Minimal, runnable configuration: a single-Region symmetric CMK with the
# module's secure defaults (rotation enabled, lockout safety check enabled),
# one alias, and tags.
#
# The key policy contains only the root-account statement, so access is
# governed entirely by IAM policies in this account. See examples/complete for
# key_administrators / key_users / key_service_users, grants, and
# multi-Region replicas.
#
# Usage:
#   terraform init
#   terraform apply
#   terraform destroy
#
# Note: applying this example creates billable resources. `terraform destroy`
# schedules the key for deletion after deletion_window_in_days; the alias is
# removed immediately.
###############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Org-/account-wide tags belong here rather than in the module's `tags`
  # input, so every resource in the configuration inherits them.
  default_tags {
    tags = {
      Example   = "kms/basic"
      ManagedBy = "Terraform"
    }
  }
}

#------------------------------------------------------------------------------
# Inputs
#
# Kept in this file to make the example a single self-contained read. Split
# into variables.tf / outputs.tf if this example grows.
#------------------------------------------------------------------------------
variable "region" {
  description = "AWS region to create the example key in."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name used for the key alias. Must be unique within the region."
  type        = string
  default     = "example-basic"
}

#------------------------------------------------------------------------------
# KMS key
#------------------------------------------------------------------------------
module "kms" {
  source = "../../"

  description = "Example symmetric encryption key (terraform module: kms/basic)"

  aliases = [var.name]

  # 7 days is the minimum, chosen here so the example tears down cheaply.
  # Production keys should keep the module default of 30 days, which leaves a
  # wider window to cancel an accidental deletion.
  deletion_window_in_days = 7

  tags = {
    Name = var.name
  }
}

#------------------------------------------------------------------------------
# Outputs
#------------------------------------------------------------------------------
output "key_arn" {
  description = "ARN of the example KMS key."
  value       = module.kms.key_arn
}

output "key_id" {
  description = "ID of the example KMS key."
  value       = module.kms.key_id
}

output "alias_arn" {
  description = "ARN of the alias created for the example key."
  value       = module.kms.aliases[var.name].arn
}

output "alias_name" {
  description = "Normalized alias name (alias/<name>)."
  value       = module.kms.aliases[var.name].name
}
