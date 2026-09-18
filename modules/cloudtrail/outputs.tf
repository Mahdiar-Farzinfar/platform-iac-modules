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
# AWS CloudTrail Module — Outputs
#
# Exposes the identifiers required to integrate this trail with downstream
# infrastructure: metric filters and alarms on the log group, Athena tables or
# EventBridge rules over the S3 bucket, and KMS grants for cross-account
# log consumers.
#
# Convention:
#   Attributes of resources created under `count` are read with
#   `one(resource[*].attribute)`, which yields `null` when the feature is
#   disabled instead of failing with an index-out-of-range error. Callers can
#   therefore reference any output unconditionally and use `try()`/`coalesce()`
#   or `!= null` checks on their side.
###############################################################################

#------------------------------------------------------------------------------
# CloudTrail
#------------------------------------------------------------------------------
output "trail_id" {
  description = "Name (ID) of the CloudTrail trail, as tracked by Terraform state."
  value       = aws_cloudtrail.this.id
}

output "trail_arn" {
  description = "ARN of the CloudTrail trail. Use this for `aws:SourceArn` conditions in external resource policies."
  value       = aws_cloudtrail.this.arn
}

output "trail_name" {
  description = "Name of the CloudTrail trail."
  value       = aws_cloudtrail.this.name
}

output "trail_home_region" {
  description = "Region in which the trail was created. For a multi-region trail this is the home region that owns the configuration."
  value       = aws_cloudtrail.this.home_region
}

output "trail_is_multi_region" {
  description = "Whether the trail captures events from all regions."
  value       = aws_cloudtrail.this.is_multi_region_trail
}

output "trail_logging_enabled" {
  description = "Whether the trail is actively delivering events. A trail can exist with logging stopped."
  value       = aws_cloudtrail.this.enable_logging
}

#------------------------------------------------------------------------------
# KMS
#------------------------------------------------------------------------------
output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the log files — the module-managed CMK when `create_kms_key` is true, otherwise the caller-supplied `kms_key_arn`. Null when no CMK is in use (logs fall back to SSE-S3 / AWS-managed encryption)."
  value       = local.kms_key_arn
}

output "kms_key_id" {
  description = "Key ID of the module-managed CMK. Null when `create_kms_key` is false, including when an external key ARN is supplied."
  value       = one(aws_kms_key.cloudtrail[*].key_id)
}

output "kms_key_alias_arn" {
  description = "ARN of the alias pointing at the module-managed CMK. Null when `create_kms_key` is false."
  value       = one(aws_kms_alias.cloudtrail[*].arn)
}

output "kms_key_alias_name" {
  description = "Alias name (`alias/<trail-name>`) of the module-managed CMK. Null when `create_kms_key` is false."
  value       = one(aws_kms_alias.cloudtrail[*].name)
}

output "kms_key_created" {
  description = "Whether this module created and therefore owns the lifecycle of the KMS key."
  value       = var.create_kms_key
}

#------------------------------------------------------------------------------
# SNS Notifications
#------------------------------------------------------------------------------
output "sns_topic_arn" {
  description = "ARN of the SNS topic used by CloudTrail for delivery notifications. Null when SNS notifications are disabled."
  value       = one(aws_sns_topic.cloudtrail[*].arn)
}

output "sns_topic_name" {
  description = "Name of the SNS topic used by CloudTrail for delivery notifications. Null when SNS notifications are disabled."
  value       = one(aws_sns_topic.cloudtrail[*].name)
}

#------------------------------------------------------------------------------
# S3
#------------------------------------------------------------------------------
output "s3_bucket_id" {
  description = "Name of the S3 bucket receiving the log files, whether created by this module or supplied by the caller."
  value       = var.create_s3_bucket ? one(aws_s3_bucket.cloudtrail[*].id) : var.s3_bucket_name
}

output "s3_bucket_arn" {
  description = "ARN of the module-created log bucket. Null when `create_s3_bucket` is false, since the ARN of an externally managed bucket is not read by this module."
  value       = one(aws_s3_bucket.cloudtrail[*].arn)
}

output "s3_bucket_domain_name" {
  description = "Global domain name of the module-created log bucket. Null when `create_s3_bucket` is false."
  value       = one(aws_s3_bucket.cloudtrail[*].bucket_domain_name)
}

output "s3_bucket_regional_domain_name" {
  description = "Region-specific domain name of the module-created log bucket. Prefer this over the global name to avoid cross-region request redirects. Null when `create_s3_bucket` is false."
  value       = one(aws_s3_bucket.cloudtrail[*].bucket_regional_domain_name)
}

output "s3_key_prefix" {
  description = "Normalized key prefix (no leading or trailing slashes) under which log files are delivered."
  value       = local.s3_key_prefix
}

output "s3_log_path_prefix" {
  description = "Full S3 key prefix of delivered log objects, including the CloudTrail-managed `AWSLogs/<account-id>/` segment. Useful as the `LOCATION` for an Athena table or as an EventBridge/S3 notification filter."
  value       = "${local.s3_key_prefix}/AWSLogs/${local.account_id}/CloudTrail"
}

output "s3_bucket_created" {
  description = "Whether this module created and therefore owns the lifecycle of the log bucket."
  value       = var.create_s3_bucket
}

#------------------------------------------------------------------------------
# CloudWatch Logs
#------------------------------------------------------------------------------
output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group receiving events. Null when `enable_cloudwatch_logs` is false. Pass this to `aws_cloudwatch_log_metric_filter` to build CIS-style alarms."
  value       = one(aws_cloudwatch_log_group.cloudtrail[*].name)
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group. Null when `enable_cloudwatch_logs` is false. Note this ARN has no trailing `:*`; CloudTrail itself requires that suffix, which the module appends internally."
  value       = one(aws_cloudwatch_log_group.cloudtrail[*].arn)
}

output "cloudwatch_logs_role_arn" {
  description = "ARN of the IAM role CloudTrail assumes to write to CloudWatch Logs. Always created, so it is non-null even when log delivery is disabled."
  value       = aws_iam_role.cloudwatch_logs.arn
}

output "cloudwatch_logs_role_name" {
  description = "Name of the IAM role CloudTrail assumes to write to CloudWatch Logs."
  value       = aws_iam_role.cloudwatch_logs.name
}

#------------------------------------------------------------------------------
# Aggregate
#------------------------------------------------------------------------------
output "tags" {
  description = "Effective tag set applied to every taggable resource in this module, after merging caller tags with module-managed provenance tags."
  value       = local.tags
}
