# -----------------------------------------------------------------------------
# TFLint strict configuration for Terraform module
# Repo: platform-iac-modules
# Purpose: CI quality gate with high signal / low noise
# -----------------------------------------------------------------------------

format = "default"
force = false

# -----------------------------------------------------------------------------
# Plugins
# -----------------------------------------------------------------------------
plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.36.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# -----------------------------------------------------------------------------
# Terraform language & module quality rules
# -----------------------------------------------------------------------------

# Modern syntax / hygiene
rule "terraform_deprecated_interpolation" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_deprecated_index" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_empty_list_equality" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_map_duplicate_keys" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_unused_declarations" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_unused_required_providers" {
  enabled  = true
  severity = "ERROR"
}

# Versioning / provider discipline
rule "terraform_required_version" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_required_providers" {
  enabled  = true
  severity = "ERROR"
}

# Module contracts (important for public/shared module repos)
rule "terraform_typed_variables" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_documented_variables" {
  enabled  = true
  severity = "ERROR"
}

rule "terraform_documented_outputs" {
  enabled  = true
  severity = "ERROR"
}

# Structure consistency across modules
rule "terraform_standard_module_structure" {
  enabled  = true
  severity = "ERROR"
}

# Optional style signal (keep as warning to reduce friction)
rule "terraform_comment_syntax" {
  enabled  = true
  severity = "WARNING"
}

# -----------------------------------------------------------------------------
# AWS provider / resources strict checks
# -----------------------------------------------------------------------------

rule "aws_provider_version" {
  enabled  = true
  severity = "ERROR"
}

# EC2 validation
rule "aws_instance_invalid_ami" {
  enabled  = true
  severity = "ERROR"
}

rule "aws_instance_invalid_type" {
  enabled  = true
  severity = "ERROR"
}

# IAM policy correctness
rule "aws_iam_policy_invalid_policy" {
  enabled  = true
  severity = "ERROR"
}

# S3 security posture
rule "aws_s3_bucket_invalid_name" {
  enabled  = true
  severity = "ERROR"
}

rule "aws_s3_bucket_invalid_acl" {
  enabled  = true
  severity = "ERROR"
}

rule "aws_s3_bucket_public_read_acl" {
  enabled  = true
  severity = "ERROR"
}

rule "aws_s3_bucket_public_write_acl" {
  enabled  = true
  severity = "ERROR"
}

# -----------------------------------------------------------------------------
# Notes
# - This file is intentionally strict to protect module quality in CI.
# - For local dev ergonomics, keep same config and allow selective ignores
#   via inline comments only with justification in code review.
# -----------------------------------------------------------------------------
