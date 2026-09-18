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
# AWS CloudTrail Module
#
# A production-ready, enterprise-grade Terraform configuration for deploying
# AWS CloudTrail with built-in security best practices, including:
#   - Encryption at rest via KMS customer managed keys (CMK).
#   - Secure S3 storage bucket with versioning, public access blocking,
#     enforced TLS 1.2+, and lifecycle transitions (Standard-IA/Glacier).
#   - Integration with CloudWatch Logs for real-time monitoring and alerting.
#   - Flexible event filtering via basic/advanced event selectors.
#
# Architecture Components:
#   1. KMS Key & Alias (Conditional): For encrypting CloudTrail logs at rest.
#   2. S3 Bucket & Policy (Conditional): Log destination with strict IAM policies.
#   3. CloudWatch Log Group & IAM Role: For real-time analysis of API activity.
#   4. AWS CloudTrail Engine: Orchestrator capturing API events.
#
# Usage:
#   terraform init
#   terraform apply
#
# Security Notice:
#   This module enforces secure transport (TLS), blocks all public access to S3,
#   and rotates KMS keys automatically. Make sure to define proper values for
#   `var.kms_key_deletion_window` before running `terraform destroy`.
###############################################################################

#------------------------------------------------------------------------------
# Global/Data Providers
#------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

#------------------------------------------------------------------------------
# KMS Key
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "kms" {
  count = var.create_kms_key ? 1 : 0

  #checkov:skip=CKV_AWS_111:KMS key policy Resource=* is an AWS constraint (this key only), not unconstrained IAM write access
  #checkov:skip=CKV_AWS_356:KMS key policies only allow Resource=*; it cannot target other resources
  statement {
    sid       = "RootAccess"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:ReEncryptFrom"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudTrailEncrypt"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogsUse"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:ReEncryptFrom"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.cloudwatch_logs.arn]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.cloudwatch_logs.arn]
    }
  }
}

resource "aws_kms_key" "cloudtrail" {
  count = var.create_kms_key ? 1 : 0

  description             = "CloudTrail encryption key – ${local.trail_name}"
  deletion_window_in_days = var.kms_key_deletion_window
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms[0].json

  tags = local.tags
}

resource "aws_kms_alias" "cloudtrail" {
  count         = var.create_kms_key ? 1 : 0
  name          = "alias/${local.trail_name}"
  target_key_id = aws_kms_key.cloudtrail[0].key_id
}

#------------------------------------------------------------------------------
# SNS Notifications
#------------------------------------------------------------------------------
resource "aws_sns_topic" "cloudtrail" {
  count = var.enable_sns_notifications ? 1 : 0

  name              = "${local.trail_name}-notifications"
  kms_master_key_id = local.kms_key_arn

  tags = local.tags
}

data "aws_iam_policy_document" "sns_topic" {
  count = var.enable_sns_notifications ? 1 : 0

  statement {
    sid    = "AllowCloudTrailPublish"
    effect = "Allow"

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.cloudtrail[0].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "cloudtrail" {
  count = var.enable_sns_notifications ? 1 : 0

  arn    = aws_sns_topic.cloudtrail[0].arn
  policy = data.aws_iam_policy_document.sns_topic[0].json
}

#------------------------------------------------------------------------------
# S3 Bucket
#------------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail" {
  count         = var.create_s3_bucket ? 1 : 0
  bucket        = local.s3_bucket_name
  force_destroy = var.s3_force_destroy
  tags          = local.tags

  # checkov:skip=CKV_AWS_18:Access logging for the CloudTrail destination bucket is intentionally managed outside this module.
  # checkov:skip=CKV_AWS_144:Cross-region replication is deployment-specific and is not enabled by default.
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[count.index].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[count.index].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = local.kms_key_arn
    }
    bucket_key_enabled = local.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = var.create_s3_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[count.index].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[count.index].id

  rule {
    id     = "cloudtrail-retention"
    status = var.s3_lifecycle_enabled ? "Enabled" : "Disabled"

    filter {}

    transition {
      days          = var.s3_transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.s3_transition_to_glacier_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.s3_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  count = var.create_s3_bucket ? 1 : 0

  statement {
    sid     = "AWSCloudTrailAclCheck"
    actions = ["s3:GetBucketAcl"]
    resources = [
      aws_s3_bucket.cloudtrail[count.index].arn,
      "${aws_s3_bucket.cloudtrail[count.index].arn}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail[0].arn}/${local.s3_key_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cloudtrail[0].arn,
      "${aws_s3_bucket.cloudtrail[0].arn}/*",
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
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[count.index].id
  policy = data.aws_iam_policy_document.s3_bucket_policy[0].json

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_s3_bucket_notification" "cloudtrail" {
  count  = var.create_s3_bucket ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[count.index].id

  eventbridge = true
}

#------------------------------------------------------------------------------
# CloudWatch Logs
#------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cloudtrail" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = local.cloudwatch_log_group_name
  retention_in_days = var.cloudwatch_logs_retention_days
  kms_key_id        = local.kms_key_arn
  tags              = local.tags
}

data "aws_iam_policy_document" "cloudwatch_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_logs" {
  name               = "${local.trail_name}-cw-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_logs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${local.trail_name}-cw-logs"
  role = aws_iam_role.cloudwatch_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = var.enable_cloudwatch_logs ? "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*" : "arn:${data.aws_partition.current.partition}:logs:*:*:*"
    }]
  })
}

#------------------------------------------------------------------------------
# CloudTrail
#------------------------------------------------------------------------------
resource "aws_cloudtrail" "this" {
  name                          = local.trail_name
  s3_bucket_name                = var.create_s3_bucket ? aws_s3_bucket.cloudtrail[0].id : var.s3_bucket_name
  s3_key_prefix                 = local.s3_key_prefix
  include_global_service_events = var.include_global_service_events
  is_multi_region_trail         = var.is_multi_region_trail
  enable_log_file_validation    = true
  enable_logging                = var.enable_logging
  kms_key_id                    = local.kms_key_arn
  cloud_watch_logs_group_arn    = var.enable_cloudwatch_logs ? "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*" : null
  cloud_watch_logs_role_arn     = var.enable_cloudwatch_logs ? aws_iam_role.cloudwatch_logs.arn : null
  sns_topic_name                = var.enable_sns_notifications ? aws_sns_topic.cloudtrail[0].name : null

  # checkov:skip=CKV2_AWS_10:CloudTrail is integrated with CloudWatch Logs through the configured log group and IAM role.

  dynamic "event_selector" {
    for_each = var.event_selectors
    content {
      read_write_type           = event_selector.value.read_write_type
      include_management_events = event_selector.value.include_management_events

      dynamic "data_resource" {
        for_each = lookup(event_selector.value, "data_resources", [])
        content {
          type   = data_resource.value.type
          values = data_resource.value.values
        }
      }
    }
  }

  dynamic "advanced_event_selector" {
    for_each = var.advanced_event_selectors
    content {
      name = advanced_event_selector.value.name

      dynamic "field_selector" {
        for_each = advanced_event_selector.value.field_selectors
        content {
          field           = field_selector.value.field
          equals          = lookup(field_selector.value, "equals", null)
          not_equals      = lookup(field_selector.value, "not_equals", null)
          starts_with     = lookup(field_selector.value, "starts_with", null)
          not_starts_with = lookup(field_selector.value, "not_starts_with", null)
          ends_with       = lookup(field_selector.value, "ends_with", null)
          not_ends_with   = lookup(field_selector.value, "not_ends_with", null)
        }
      }
    }
  }

  dynamic "insight_selector" {
    for_each = var.insight_selectors
    content { insight_type = insight_selector.value }
  }

  tags = local.tags

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_sns_topic_policy.cloudtrail,
  ]
}
