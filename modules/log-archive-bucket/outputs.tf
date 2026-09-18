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
# Log Archive Bucket Module — outputs.tf
###############################################################################

output "bucket_id" {
  description = "The name (ID) of the S3 bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket. Use this to grant IAM permissions."
  value       = aws_s3_bucket.this.arn
}

output "bucket_domain_name" {
  description = "Bucket-regional domain name (path-style). Suitable for CloudFront origins."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "bucket_region" {
  description = "AWS region the bucket was created in."
  value       = aws_s3_bucket.this.region
}

output "versioning_status" {
  description = "Current versioning state of the bucket (always 'Enabled' for this module)."
  value       = aws_s3_bucket_versioning.this.versioning_configuration[0].status
}

output "encryption_algorithm" {
  description = "SSE algorithm in use: 'aws:kms' when a KMS key is supplied, otherwise 'AES256'."
  value       = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for SSE-KMS encryption. Null when AES256 is used."
  value       = var.kms_key_arn
}

output "object_lock_enabled" {
  description = "Whether S3 Object Lock (WORM) is active on this bucket."
  value       = var.object_lock_enabled
}

output "tags" {
  description = "Effective tag map applied to the bucket (module defaults merged with caller tags)."
  value       = local.tags
}
