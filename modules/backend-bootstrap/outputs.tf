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
# Backend Bootstrap — Outputs
#
# Exposes identifiers consumers need to configure their `backend "s3"` block
# and to wire IAM policies against the state bucket / lock table.
###############################################################################

# -----------------------------------------------------------------------------
# State bucket
# -----------------------------------------------------------------------------
output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket (for IAM policy statements)."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region of the state bucket (use as `region` in backend config)."
  value       = aws_s3_bucket.state.region
}

# -----------------------------------------------------------------------------
# Lock table
# -----------------------------------------------------------------------------
output "lock_table_name" {
  description = "Name of the DynamoDB table used for state locking."
  value       = aws_dynamodb_table.lock.name
}

output "lock_table_arn" {
  description = "ARN of the lock table (for IAM policy statements)."
  value       = aws_dynamodb_table.lock.arn
}

# -----------------------------------------------------------------------------
# Access logs bucket (optional)
# -----------------------------------------------------------------------------
output "access_logs_bucket_name" {
  description = "Name of the access-logs bucket, or null if logging is disabled."
  value       = one(aws_s3_bucket.access_logs[*].bucket)
}

output "access_logs_bucket_arn" {
  description = "ARN of the access-logs bucket, or null if logging is disabled."
  value       = one(aws_s3_bucket.access_logs[*].arn)
}

# -----------------------------------------------------------------------------
# Encryption
# -----------------------------------------------------------------------------
output "kms_key_arn" {
  description = "KMS key ARN used to encrypt state objects and the lock table."
  value       = var.kms_key_arn
}

# -----------------------------------------------------------------------------
# Ready-to-use backend configuration
# -----------------------------------------------------------------------------
output "backend_config" {
  description = "Backend settings as a map — usable with `terraform init -backend-config` or in automation."
  value = {
    bucket         = aws_s3_bucket.state.bucket
    key            = "terraform.tfstate" # adjust per consuming stack
    region         = aws_s3_bucket.state.region
    dynamodb_table = aws_dynamodb_table.lock.name
    encrypt        = true
    kms_key_id     = var.kms_key_arn
  }
}

output "backend_hcl_snippet" {
  description = "Copy-paste `backend \"s3\"` block for consuming Terraform projects."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.bucket}"
        key            = "platform-iac-modules/backend-bootstrap/terraform.tfstate"
        region         = "${aws_s3_bucket.state.region}"
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
        encrypt        = true
        kms_key_id     = "${var.kms_key_arn}"
      }
    }
  EOT
}
