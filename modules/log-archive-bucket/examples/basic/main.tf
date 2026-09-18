# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# Log Archive Bucket Module — examples/basic
#
# Description:
#   Minimal, copy-paste-ready consumption of the log-archive-bucket module.
#   Demonstrates the smallest sensible input surface: a bucket name, tags,
#   and log-delivery principals. Everything else relies on the module's
#   safe-by-default posture (SSE-S3, versioning, TLS-only, no Object Lock).
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#
# Notes:
#   - Unlike the module itself, examples are root modules and therefore DO
#     declare a provider configuration.
#   - The random_pet suffix keeps the example re-runnable without colliding
#     with the globally unique S3 namespace. Real deployments should use a
#     deterministic name instead.
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = "example"
      Project     = "log-archive-bucket-basic"
    }
  }
}

variable "region" {
  description = "AWS region to deploy the example into."
  type        = string
  default     = "eu-central-1"
}

# S3 bucket names are globally unique; a short random suffix makes the
# example safely re-runnable across accounts and CI pipelines.
resource "random_pet" "suffix" {
  length = 2
}

module "log_archive" {
  source = "../.."

  bucket_name = "example-log-archive-${random_pet.suffix.id}"

  # CloudTrail and the unified log-delivery service (ALB/NLB access logs,
  # VPC Flow Logs) may write into this bucket, scoped to this account.
  log_delivery_service_principals = [
    "cloudtrail.amazonaws.com",
    "delivery.logs.amazonaws.com",
  ]

  # Example only — never enable force_destroy on real audit buckets.
  force_destroy = true

  tags = {
    Owner = "platform-team"
  }
}

output "bucket_id" {
  description = "Name of the created log archive bucket."
  value       = module.log_archive.bucket_id
}

output "bucket_arn" {
  description = "ARN of the created log archive bucket."
  value       = module.log_archive.bucket_arn
}

output "encryption_algorithm" {
  description = "Effective SSE algorithm (AES256 in this basic example)."
  value       = module.log_archive.encryption_algorithm
}
