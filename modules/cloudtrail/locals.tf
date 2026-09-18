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
# AWS CloudTrail Module - Local Values
#
# Centralizes all derived/computed values used across the module so that
# naming, ARN construction, and tagging remain consistent and are defined
# in exactly one place.
###############################################################################

locals {
  #----------------------------------------------------------------------------
  # Identity shortcuts
  #----------------------------------------------------------------------------
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition

  #----------------------------------------------------------------------------
  # Trail
  #----------------------------------------------------------------------------
  trail_name = var.trail_name

  # The trail ARN is constructed (not referenced from the resource) because the
  # S3 bucket policy needs it *before* the trail exists. aws_cloudtrail depends
  # on aws_s3_bucket_policy, so referencing aws_cloudtrail.this.arn there would
  # create a dependency cycle.
  trail_arn = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"

  #----------------------------------------------------------------------------
  # KMS
  #----------------------------------------------------------------------------
  # Prefer the module-managed CMK; fall back to an externally supplied key ARN.
  # Resolves to null when encryption with a CMK is not configured, which lets
  # dependent resources (S3 SSE, CloudWatch Logs) degrade gracefully to
  # AWS-managed encryption.
  kms_key_arn = var.create_kms_key ? aws_kms_key.cloudtrail[0].arn : var.kms_key_arn

  #----------------------------------------------------------------------------
  # S3
  #----------------------------------------------------------------------------
  # Bucket names are globally unique, so suffix with account ID and region
  # when the caller has not provided an explicit name.
  s3_bucket_name = coalesce(
    var.s3_bucket_name,
    lower("${local.trail_name}-${local.account_id}-${local.region}")
  )

  # Normalized prefix: strip stray slashes so both the trail configuration and
  # the "<bucket-arn>/<prefix>/AWSLogs/..." path in the bucket policy stay in
  # sync. Must be non-empty; main.tf interpolates it into the policy resource
  # path, and an empty value would produce a "//AWSLogs" object path that
  # CloudTrail never writes to.
  s3_key_prefix = trim(coalesce(var.s3_key_prefix, "cloudtrail"), "/")

  #----------------------------------------------------------------------------
  # CloudWatch Logs
  #----------------------------------------------------------------------------
  cloudwatch_log_group_name = coalesce(
    var.cloudwatch_log_group_name,
    "/aws/cloudtrail/${local.trail_name}"
  )

  #----------------------------------------------------------------------------
  # Tags
  #----------------------------------------------------------------------------
  # Module-level tags win over caller tags for the keys below, guaranteeing
  # consistent provenance metadata on every resource.
  tags = merge(
    var.tags,
    {
      Name      = local.trail_name
      Module    = "cloudtrail"
      ManagedBy = "terraform"
    }
  )
}
