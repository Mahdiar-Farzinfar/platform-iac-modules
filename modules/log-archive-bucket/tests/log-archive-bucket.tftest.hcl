# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# Log Archive Bucket Module — tests/log-archive-bucket.tftest.hcl
#
# Description:
#   Unit-style test suite for the log-archive-bucket module using the native
#   `terraform test` framework. All runs use `command = plan` against a
#   mocked AWS provider, so the suite:
#     - needs no AWS credentials,
#     - creates no real infrastructure,
#     - is safe and fast enough for pre-merge CI.
#
# Coverage:
#   1. Safe-by-default posture (SSE-S3, versioning, public access block,
#      no Object Lock, force_destroy off).
#   2. SSE-KMS path (algorithm switch + Bucket Key enablement).
#   3. Object Lock (WORM) configuration.
#   4. Lifecycle tiering values and optional expiration.
#   5. Tag merge semantics (caller tags survive the merge).
#   6. Fail-fast input validation via expect_failures.
#
# Usage:
#   cd modules/log-archive-bucket
#   terraform init -backend=false
#   terraform test
#
# Notes:
#   - Mock providers require Terraform >= 1.7.0 (stricter than the module's
#     own >= 1.5.0 floor; only the test suite needs 1.7+).
#   - Plan-time assertions only reference values known before apply
#     (resource arguments, counts, variables) — never computed attributes
#     such as ARNs or bucket IDs, which are unknown during plan.
###############################################################################

# ----------------------------------------------------------------------------
# Provider mocking
# ----------------------------------------------------------------------------
# The module reads aws_caller_identity for the confused-deputy guard in the
# bucket policy; pin it to a deterministic account so runs are reproducible.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAEXAMPLETEST"
    }
  }
}

# ----------------------------------------------------------------------------
# Shared inputs
# ----------------------------------------------------------------------------
# Deterministic name: tests never hit the real S3 namespace, so no random
# suffix is needed (unlike examples/basic).
variables {
  bucket_name = "tftest-log-archive"

  log_delivery_service_principals = [
    "cloudtrail.amazonaws.com",
    "delivery.logs.amazonaws.com",
  ]

  tags = {
    Owner = "platform-team"
  }
}

# ----------------------------------------------------------------------------
# 1. Safe-by-default posture
# ----------------------------------------------------------------------------
run "defaults_are_safe" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.bucket == "tftest-log-archive"
    error_message = "Bucket name must match the (normalized) bucket_name input."
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy must default to false on audit buckets."
  }

  assert {
    condition     = aws_s3_bucket.this.object_lock_enabled == false
    error_message = "Object Lock must be opt-in, not enabled by default."
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.this) == 0
    error_message = "No Object Lock configuration may be created unless explicitly enabled."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must always be Enabled."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.this.block_public_acls &&
      aws_s3_bucket_public_access_block.this.block_public_policy &&
      aws_s3_bucket_public_access_block.this.ignore_public_acls &&
      aws_s3_bucket_public_access_block.this.restrict_public_buckets
    )
    error_message = "All four public access block settings must be true."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.this.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "Object ownership must be BucketOwnerEnforced (ACLs disabled)."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Without a KMS key, encryption must fall back to SSE-S3 (AES256)."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled != true
    error_message = "Bucket Keys must be disabled when SSE-S3 is in use."
  }

  assert {
    condition     = length(aws_s3_bucket_logging.this) == 0
    error_message = "Access logging must be disabled when access_log_bucket is null."
  }
}

# ----------------------------------------------------------------------------
# 2. SSE-KMS path
# ----------------------------------------------------------------------------
run "kms_encryption_enables_bucket_key" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-central-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "Supplying kms_key_arn must switch the SSE algorithm to aws:kms."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == true
    error_message = "Bucket Keys must be enabled with SSE-KMS to reduce KMS request costs."
  }

  assert {
    condition     = output.encryption_algorithm == "aws:kms"
    error_message = "encryption_algorithm output must report aws:kms."
  }
}

# ----------------------------------------------------------------------------
# 3. Object Lock (WORM)
# ----------------------------------------------------------------------------
run "object_lock_configuration" {
  command = plan

  variables {
    object_lock_enabled        = true
    object_lock_mode           = "COMPLIANCE"
    object_lock_retention_days = 730
  }

  assert {
    condition     = aws_s3_bucket.this.object_lock_enabled == true
    error_message = "object_lock_enabled must be set on the bucket at creation time."
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.this) == 1
    error_message = "Exactly one Object Lock configuration must be created when enabled."
  }

  assert {
    condition     = aws_s3_bucket_object_lock_configuration.this[0].rule[0].default_retention[0].mode == "COMPLIANCE"
    error_message = "Object Lock retention mode must pass through unchanged."
  }

  assert {
    condition     = aws_s3_bucket_object_lock_configuration.this[0].rule[0].default_retention[0].days == 730
    error_message = "Object Lock retention days must pass through unchanged."
  }
}

# ----------------------------------------------------------------------------
# 4. Lifecycle tiering
# ----------------------------------------------------------------------------
run "lifecycle_tiering_and_expiration" {
  command = plan

  variables {
    transition_to_ia_days           = 45
    transition_to_glacier_days      = 120
    transition_to_deep_archive_days = 400
    expiration_days                 = 800
    lifecycle_prefix                = "cloudtrail/"
  }

  assert {
    condition = toset([
      for t in aws_s3_bucket_lifecycle_configuration.this.rule[0].transition :
      "${t.storage_class}:${t.days}"
    ]) == toset(["STANDARD_IA:45", "GLACIER:120", "DEEP_ARCHIVE:400"])
    error_message = "All three storage-class transitions must be present with the configured day thresholds."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this.rule[0].expiration[0].days == 800
    error_message = "Setting expiration_days must materialize an expiration block."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this.rule[0].filter[0].prefix == "cloudtrail/"
    error_message = "The lifecycle rule must be scoped to the configured prefix."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this.rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Incomplete multipart uploads must be aborted after 7 days."
  }
}

run "expiration_omitted_by_default" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule[0].expiration) == 0
    error_message = "No expiration block may exist when expiration_days is null (retain indefinitely)."
  }
}

# ----------------------------------------------------------------------------
# 5. Tag merge semantics
# ----------------------------------------------------------------------------
run "caller_tags_survive_merge" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.tags["Owner"] == "platform-team"
    error_message = "Caller-supplied tags must be present on the bucket after the merge."
  }

  assert {
    condition     = contains(keys(aws_s3_bucket.this.tags), "ManagedBy")
    error_message = "Module provenance tags (ManagedBy) must be merged into the tag map."
  }
}

# ----------------------------------------------------------------------------
# 6. Fail-fast input validation
# ----------------------------------------------------------------------------
run "rejects_invalid_bucket_name" {
  command = plan

  variables {
    bucket_name = "Invalid_Bucket_NAME"
  }

  expect_failures = [var.bucket_name]
}

run "rejects_bucket_name_with_s3alias_suffix" {
  command = plan

  variables {
    bucket_name = "my-logs-s3alias"
  }

  expect_failures = [var.bucket_name]
}

run "rejects_ia_transition_below_aws_minimum" {
  command = plan

  variables {
    transition_to_ia_days = 15
  }

  expect_failures = [var.transition_to_ia_days]
}

run "rejects_premature_expiration" {
  command = plan

  variables {
    expiration_days = 100
  }

  expect_failures = [var.expiration_days]
}

run "rejects_malformed_kms_arn" {
  command = plan

  variables {
    kms_key_arn = "not-a-kms-arn"
  }

  expect_failures = [var.kms_key_arn]
}

run "rejects_invalid_object_lock_mode" {
  command = plan

  variables {
    object_lock_enabled = true
    object_lock_mode    = "LEGAL_HOLD"
  }

  expect_failures = [var.object_lock_mode]
}

run "rejects_non_amazonaws_service_principal" {
  command = plan

  variables {
    log_delivery_service_principals = ["evil.example.com"]
  }

  expect_failures = [var.log_delivery_service_principals]
}
