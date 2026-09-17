# SPDX-License-Identifier: Apache-2.0
#
# Copyright 2026 Mahdiar Farzinfar
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################
# Backend Bootstrap — Terraform Remote State Infrastructure
#
# Provisions:
#   - S3 bucket for Terraform state (versioned, KMS-encrypted, private)
#   - Optional S3 access-logs bucket
#   - DynamoDB table for state locking (PITR + deletion protection)
#   - Bucket policies enforcing TLS-only and KMS-encrypted writes
#
# NOTE: This module intentionally avoids a remote backend itself (chicken-and-
# egg problem). Apply once with local state, then migrate via `init -migrate-state`.
###############################################################################

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# State Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_144:Cross-region replication requires a destination provider and bucket outside this bootstrap module.
  bucket        = local.state_bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name    = local.state_bucket_name
    Purpose = "terraform-remote-state"
  })

  lifecycle {
    # Guard rail: state bucket must never be destroyed accidentally.
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_notification" "state" {
  bucket      = aws_s3_bucket.state.id
  eventbridge = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    # Reduce KMS API costs on high-frequency state reads/writes.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Versioning must be enabled before noncurrent-version rules apply.
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_expiration_days
      newer_noncurrent_versions = var.noncurrent_versions_to_retain
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# -----------------------------------------------------------------------------
# State Bucket Policy — TLS-only + enforce KMS encryption on write
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyUnencryptedObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyWrongKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # Public access block must exist before applying a restrictive policy.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# Optional: Access Logs Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_18:Access-log destination buckets cannot enable server access logging to themselves.
  #checkov:skip=CKV_AWS_144:Access-log destination bucket is intentionally regional and is not replicated by this module.
  #checkov:skip=CKV_AWS_145:S3 server access log delivery requires SSE-S3 (AES256); SSE-KMS is unsupported.
  count = var.enable_access_logging ? 1 : 0

  bucket        = local.access_logs_bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name    = local.access_logs_bucket_name
    Purpose = "terraform-state-access-logs"
  })
}

resource "aws_s3_bucket_notification" "access_logs" {
  count       = var.enable_access_logging ? 1 : 0
  bucket      = aws_s3_bucket.access_logs[count.index].id
  eventbridge = true
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[count.index].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  depends_on              = [aws_s3_bucket.access_logs]
}

resource "aws_s3_bucket_versioning" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[count.index].id

  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[count.index].id

  rule {
    apply_server_side_encryption_by_default {
      # S3 server access logging does not support SSE-KMS delivery.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[count.index].id

  depends_on = [aws_s3_bucket_versioning.access_logs]

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days = var.access_logs_retention_days
    }
  }
}

resource "aws_s3_bucket_logging" "state" {
  count = var.enable_access_logging ? 1 : 0

  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.access_logs[count.index].id
  target_prefix = "state-bucket/"
}

# -----------------------------------------------------------------------------
# DynamoDB — State Locking
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(local.common_tags, {
    Name    = local.lock_table_name
    Purpose = "terraform-state-lock"
  })

  lifecycle {
    prevent_destroy = true
  }
}
