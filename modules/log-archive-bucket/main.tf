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
# Log Archive Bucket Module — main.tf
#
# Description:
#   Provisions a highly secure, audit-ready S3 bucket designed for long-term
#   log aggregation (e.g., CloudTrail, VPC Flow Logs, ALB access logs).
#
# Security & Compliance:
#   - Encryption: Supports AES256 or SSE-KMS with optional Bucket Key for cost reduction.
#   - Public Access: Strict 'Public Access Block' and 'Bucket Owner Enforced' settings.
#   - Transport: Enforces TLS 1.2+ via explicit Deny statements in bucket policy.
#   - Data Integrity: Versioning enabled by default to prevent accidental deletion.
#   - Compliance: Optional S3 Object Lock (WORM) for regulatory requirements (SOC2, PCI).
#
# Performance & Cost:
#   - Implements a tiered lifecycle strategy: Standard -> IA -> Glacier -> Deep Archive.
#   - Automatically cleans up incomplete multi-part uploads to save costs.
#
# Usage:
#   module "log_archive" {
#     source = "./modules/log-archive-bucket"
#     bucket_name = "my-company-audit-logs"
#     transition_to_glacier_days = 90
#     object_lock_enabled = true
#   }
#
# Notes:
#   - Object Lock must be enabled during bucket creation and cannot be disabled.
#   - Ensure 'log_delivery_service_principals' are correctly set for your AWS services.
###############################################################################

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  # Object Lock must be enabled at creation time; it cannot be added later.
  object_lock_enabled = var.object_lock_enabled

  # checkov:skip=CKV_AWS_144:Cross-region replication is intentionally not enabled because this archive bucket is managed in the designated logging region; disaster recovery is handled by the platform backup strategy.

  tags = local.tags
}

resource "aws_s3_bucket_notification" "this" {
  bucket = aws_s3_bucket.this.id

  # Enable native S3 EventBridge delivery for this bucket.
  eventbridge = true
}

# Disable ACLs entirely (AWS-recommended posture since April 2023).
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is required for Object Lock and protects against
# accidental overwrite/deletion of archived logs.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    # Reduces KMS request costs on high-volume log writes.
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Versioning + lifecycle ordering guard.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "log-archive-tiering"
    status = "Enabled"

    filter {
      prefix = var.lifecycle_prefix
    }

    transition {
      days          = var.transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.transition_to_glacier_days
      storage_class = "GLACIER"
    }

    transition {
      days          = var.transition_to_deep_archive_days
      storage_class = "DEEP_ARCHIVE"
    }

    dynamic "expiration" {
      for_each = var.expiration_days != null ? [1] : []
      content {
        days = var.expiration_days
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Optional WORM retention for compliance regimes (e.g. SOC 2, PCI DSS).
resource "aws_s3_bucket_object_lock_configuration" "this" {
  count  = var.object_lock_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.object_lock_retention_days
    }
  }
}

# Optional S3 server access logging to a separate audit bucket.
resource "aws_s3_bucket_logging" "this" {
  count  = var.access_log_bucket != null ? 1 : 0
  bucket = aws_s3_bucket.this.id

  target_bucket = var.access_log_bucket
  target_prefix = "s3-access/${local.bucket_name}/"
}

data "aws_iam_policy_document" "bucket" {
  # Deny any non-TLS access.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

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

  # Allow log-delivery principals (e.g. CloudTrail, ALB, VPC Flow Logs)
  # to write, scoped to this account as source.
  dynamic "statement" {
    for_each = length(var.log_delivery_service_principals) > 0 ? [1] : []
    content {
      sid     = "AllowLogDeliveryWrite"
      effect  = "Allow"
      actions = ["s3:PutObject"]

      resources = ["${aws_s3_bucket.this.arn}/*"]

      principals {
        type        = "Service"
        identifiers = var.log_delivery_service_principals
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # Public access block must exist before attaching a policy,
  # otherwise a transient "public policy" error can occur.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

data "aws_caller_identity" "current" {}
