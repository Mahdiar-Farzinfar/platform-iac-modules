# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# Backend Bootstrap — Terraform Native Tests
#
# Strategy:
#   - All runs use `command = plan` against a mocked AWS provider, so tests
#     require no credentials, create no real infrastructure, and are safe to
#     run in CI on every commit.
#   - `prevent_destroy` on the state bucket / lock table makes apply-based
#     test cleanup impossible by design; plan-only testing sidesteps that.
#   - Assertions target config-derived (known-at-plan) attributes only.
#     Computed attributes (ARNs, bucket region, generated IDs) are unknown
#     during plan and are intentionally not asserted.
#
# Requires: Terraform >= 1.7 (mock_provider support).
###############################################################################

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

# Baseline inputs shared by every run; individual runs override as needed.
variables {
  name_prefix = "acme-platform"
  kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
}

# -----------------------------------------------------------------------------
# Happy path — defaults
# -----------------------------------------------------------------------------
run "defaults_naming_and_conditional_resources" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "acme-platform-tfstate-123456789012"
    error_message = "State bucket name must be <name_prefix>-tfstate-<account_id>."
  }

  assert {
    condition     = aws_dynamodb_table.lock.name == "acme-platform-tfstate-lock"
    error_message = "Lock table name must be <name_prefix>-tfstate-lock (no account suffix)."
  }

  assert {
    condition     = length(aws_s3_bucket.access_logs) == 1
    error_message = "Access-logs bucket must be created by default (enable_access_logging defaults to true)."
  }

  assert {
    condition     = aws_s3_bucket.access_logs[0].bucket == "acme-platform-tfstate-logs-123456789012"
    error_message = "Access-logs bucket name must be <name_prefix>-tfstate-logs-<account_id>."
  }

  assert {
    condition     = length(aws_s3_bucket_logging.state) == 1
    error_message = "S3 server access logging must be wired to the state bucket by default."
  }

  assert {
    condition     = aws_s3_bucket_logging.state[0].target_prefix == "state-bucket/"
    error_message = "Access-log delivery must use the 'state-bucket/' prefix."
  }
}

run "defaults_security_posture" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket versioning must be enabled."
  }

  assert {
    condition = (
      one(aws_s3_bucket_server_side_encryption_configuration.state.rule)
      .apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" &&
      one(aws_s3_bucket_server_side_encryption_configuration.state.rule)
      .apply_server_side_encryption_by_default[0].kms_master_key_id == var.kms_key_arn
    )
    error_message = "State bucket must default to SSE-KMS with the caller-provided key."
  }

  assert {
    condition = one(
      aws_s3_bucket_server_side_encryption_configuration.state.rule
    ).bucket_key_enabled == true
    error_message = "S3 Bucket Keys must be enabled to reduce KMS request costs."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls == true &&
      aws_s3_bucket_public_access_block.state.block_public_policy == true &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls == true &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets == true
    )
    error_message = "All four public-access-block settings must be enabled on the state bucket."
  }

  assert {
    condition = one(
      aws_s3_bucket_ownership_controls.state.rule
    ).object_ownership == "BucketOwnerEnforced"
    error_message = "State bucket must enforce BucketOwnerEnforced ownership (ACLs disabled)."
  }

  assert {
    condition = one(
      aws_s3_bucket_server_side_encryption_configuration.access_logs[0].rule
    ).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Access-logs bucket must use SSE-S3 (AES256); S3 log delivery does not support SSE-KMS."
  }
}

run "defaults_lifecycle_and_lock_table" {
  command = plan

  assert {
    condition = (
      one(aws_s3_bucket_lifecycle_configuration.state.rule)
      .noncurrent_version_expiration[0].noncurrent_days == 90 &&
      one(aws_s3_bucket_lifecycle_configuration.state.rule)
      .noncurrent_version_expiration[0].newer_noncurrent_versions == 10
    )
    error_message = "Default lifecycle must expire noncurrent versions after 90 days while retaining the 10 newest."
  }

  assert {
    condition = one(
      aws_s3_bucket_lifecycle_configuration.state.rule
    ).abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Incomplete multipart uploads must be aborted after 7 days."
  }

  assert {
    condition = one(
      aws_s3_bucket_lifecycle_configuration.access_logs[0].rule
    ).expiration[0].days == 365
    error_message = "Access logs must expire after 365 days by default."
  }

  assert {
    condition = (
      aws_dynamodb_table.lock.billing_mode == "PAY_PER_REQUEST" &&
      aws_dynamodb_table.lock.hash_key == "LockID"
    )
    error_message = "Lock table must be on-demand with 'LockID' as the hash key (Terraform S3 backend contract)."
  }

  assert {
    condition     = aws_dynamodb_table.lock.point_in_time_recovery[0].enabled == true
    error_message = "Lock table must have point-in-time recovery enabled."
  }

  assert {
    condition = (
      aws_dynamodb_table.lock.server_side_encryption[0].enabled == true &&
      aws_dynamodb_table.lock.server_side_encryption[0].kms_key_arn == var.kms_key_arn
    )
    error_message = "Lock table must be encrypted with the caller-provided KMS key."
  }

  assert {
    condition     = aws_dynamodb_table.lock.deletion_protection_enabled == true
    error_message = "Lock table deletion protection must be enabled by default."
  }
}

# -----------------------------------------------------------------------------
# Bucket policy — TLS-only + KMS enforcement
# -----------------------------------------------------------------------------
run "state_bucket_policy_statements" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["DenyInsecureTransport", "DenyUnencryptedObjectUploads", "DenyWrongKmsKey"] :
      contains(data.aws_iam_policy_document.state.statement[*].sid, sid)
    ])
    error_message = "Bucket policy must contain the TLS-only, encrypted-upload, and correct-KMS-key deny statements."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.state.statement : s.effect == "Deny"
    ])
    error_message = "All bucket-policy statements must be explicit denies."
  }
}

# -----------------------------------------------------------------------------
# Feature toggles
# -----------------------------------------------------------------------------
run "access_logging_disabled" {
  command = plan

  variables {
    enable_access_logging = false
  }

  assert {
    condition = (
      length(aws_s3_bucket.access_logs) == 0 &&
      length(aws_s3_bucket_public_access_block.access_logs) == 0 &&
      length(aws_s3_bucket_server_side_encryption_configuration.access_logs) == 0 &&
      length(aws_s3_bucket_lifecycle_configuration.access_logs) == 0 &&
      length(aws_s3_bucket_logging.state) == 0
    )
    error_message = "Disabling access logging must suppress every logging-related resource."
  }
}

run "deletion_protection_disabled" {
  command = plan

  variables {
    enable_deletion_protection = false
  }

  assert {
    condition     = aws_dynamodb_table.lock.deletion_protection_enabled == false
    error_message = "enable_deletion_protection=false must propagate to the lock table."
  }
}

# -----------------------------------------------------------------------------
# Tagging contract
# -----------------------------------------------------------------------------
run "module_tags_win_over_caller_tags" {
  command = plan

  variables {
    environment = "prod"
    tags = {
      ManagedBy = "click-ops" # must be overridden by the module
      CostCode  = "cc-1234"   # must pass through
    }
  }

  assert {
    condition = (
      aws_s3_bucket.state.tags["ManagedBy"] == "terraform" &&
      aws_s3_bucket.state.tags["Module"] == "backend-bootstrap" &&
      aws_s3_bucket.state.tags["Environment"] == "prod" &&
      aws_s3_bucket.state.tags["CostCode"] == "cc-1234"
    )
    error_message = "Module-managed tags must take precedence over caller tags; caller-only tags must pass through."
  }

  assert {
    condition     = aws_dynamodb_table.lock.tags["Purpose"] == "terraform-state-lock"
    error_message = "Lock table must carry the terraform-state-lock Purpose tag."
  }
}

# -----------------------------------------------------------------------------
# Input validation — negative tests
# -----------------------------------------------------------------------------
run "rejects_invalid_name_prefix" {
  command = plan

  variables {
    name_prefix = "Bad_Prefix!"
  }

  expect_failures = [var.name_prefix]
}

run "rejects_name_prefix_with_leading_hyphen" {
  command = plan

  variables {
    name_prefix = "-acme"
  }

  expect_failures = [var.name_prefix]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "rejects_kms_alias_instead_of_key_arn" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:alias/terraform-state"
  }

  expect_failures = [var.kms_key_arn]
}

run "rejects_out_of_range_lifecycle_values" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 0
    noncurrent_versions_to_retain      = 150
    access_logs_retention_days         = 0
  }

  expect_failures = [
    var.noncurrent_version_expiration_days,
    var.noncurrent_versions_to_retain,
    var.access_logs_retention_days,
  ]
}
