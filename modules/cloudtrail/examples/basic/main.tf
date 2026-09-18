# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# Basic Example — AWS CloudTrail Module
#
# Deploys the module with its secure defaults:
#   - Multi-region trail with log file validation.
#   - Module-managed KMS CMK with automatic rotation.
#   - Module-managed S3 bucket (versioned, encrypted, TLS-only, lifecycle).
#   - CloudWatch Logs delivery with 365-day retention.
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# Teardown notice:
#   `s3_force_destroy` and a short `kms_key_deletion_window` are set below so
#   the example can be destroyed cleanly. Do NOT copy those two settings into
#   a production configuration — audit logs should never be trivially
#   destructible.
###############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # Tags applied by the provider to every resource, complementing the
  # module-level tags below.
  default_tags {
    tags = {
      Environment = "example"
      ManagedBy   = "terraform"
      Repository  = "terraform-aws-cloudtrail"
    }
  }
}

#------------------------------------------------------------------------------
# CloudTrail
#------------------------------------------------------------------------------
module "cloudtrail" {
  source = "../.."

  # Required
  trail_name = "example-basic-trail"

  # Everything below is optional and shown here only to make the example's
  # behavior explicit; these match the module defaults.
  is_multi_region_trail          = true
  include_global_service_events  = true
  enable_cloudwatch_logs         = true
  enable_sns_notifications       = true
  cloudwatch_logs_retention_days = 365

  create_kms_key   = true
  create_s3_bucket = true

  # Example-only settings for painless `terraform destroy`.
  # Never use these values in production (see header notice).
  s3_force_destroy        = true
  kms_key_deletion_window = 7

  tags = {
    Project = "cloudtrail-module-examples"
    Example = "basic"
  }
}

#------------------------------------------------------------------------------
# Outputs
#------------------------------------------------------------------------------
# Re-exported so `terraform output` after apply demonstrates what the module
# returns and gives copy-pasteable identifiers for manual verification
# (e.g. `aws cloudtrail get-trail-status --name $(terraform output -raw trail_name)`).

output "trail_arn" {
  description = "ARN of the created CloudTrail trail."
  value       = module.cloudtrail.trail_arn
}

output "trail_name" {
  description = "Name of the created CloudTrail trail."
  value       = module.cloudtrail.trail_name
}

output "s3_bucket_id" {
  description = "Name of the S3 bucket receiving the log files."
  value       = module.cloudtrail.s3_bucket_id
}

output "s3_log_path_prefix" {
  description = "Full S3 key prefix under which log objects are delivered."
  value       = module.cloudtrail.s3_log_path_prefix
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the logs."
  value       = module.cloudtrail.kms_key_arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group receiving real-time events."
  value       = module.cloudtrail.cloudwatch_log_group_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for CloudTrail delivery notifications."
  value       = module.cloudtrail.sns_topic_arn
}

output "sns_topic_name" {
  description = "Name of the SNS topic used for CloudTrail delivery notifications."
  value       = module.cloudtrail.sns_topic_name
}
