# -----------------------------------------------------------------------------
# TFLint strict configuration for Terraform module
# Repo: platform-iac-modules
# Purpose: CI quality gate with high signal / low noise
# -----------------------------------------------------------------------------

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
}

rule "terraform_deprecated_index" {
  enabled  = true
}

rule "terraform_empty_list_equality" {
  enabled  = true
}

rule "terraform_map_duplicate_keys" {
  enabled  = true
}

rule "terraform_unused_declarations" {
  enabled  = true
}

rule "terraform_unused_required_providers" {
  enabled  = true
}

# Versioning / provider discipline
rule "terraform_required_version" {
  enabled  = true
}

rule "terraform_required_providers" {
  enabled  = true
}

# Module contracts (important for public/shared module repos)
rule "terraform_typed_variables" {
  enabled  = true
}

rule "terraform_documented_variables" {
  enabled  = true
}

rule "terraform_documented_outputs" {
  enabled  = true
}

# Structure consistency across modules
# Intentionally disabled for now because this repository currently permits
# variables/outputs in main.tf across existing module examples.
# Re-enable only after repository-wide structure and documentation alignment.
rule "terraform_standard_module_structure" {
  enabled  = false
}

# Optional style signal (keep as warning to reduce friction)
rule "terraform_comment_syntax" {
  enabled  = true
}

# -----------------------------------------------------------------------------
# AWS provider / resources strict checks
# -----------------------------------------------------------------------------

# EC2 validation
rule "aws_instance_invalid_ami" {
  enabled  = true
}

rule "aws_instance_invalid_type" {
  enabled  = true
}

# IAM policy correctness
rule "aws_iam_policy_invalid_policy" {
  enabled  = true
}

# S3 security posture
rule "aws_s3_bucket_invalid_acl" {
  enabled  = true
}

# -----------------------------------------------------------------------------
# Notes
# - This file is intentionally strict to protect module quality in CI.
# - For local dev ergonomics, keep same config and allow selective ignores
#   via inline comments only with a clear justification.
# -----------------------------------------------------------------------------
