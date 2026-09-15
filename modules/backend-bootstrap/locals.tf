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
# Backend Bootstrap — Local Values
#
# Centralizes derived naming and tagging so resource blocks stay declarative.
# Bucket names embed the account ID to guarantee global S3 uniqueness across
# accounts sharing the same name_prefix.
###############################################################################

locals {
  account_id = data.aws_caller_identity.current.account_id

  # ---------------------------------------------------------------------------
  # Derived resource names
  # ---------------------------------------------------------------------------
  # S3 bucket names are globally unique; suffixing with the account ID makes
  # the same module safely reusable across accounts without name collisions.
  state_bucket_name       = "${var.name_prefix}-tfstate-${local.account_id}"
  access_logs_bucket_name = "${var.name_prefix}-tfstate-logs-${local.account_id}"

  # DynamoDB table names are only account/region-scoped, so no suffix needed.
  lock_table_name = "${var.name_prefix}-tfstate-lock"

  # ---------------------------------------------------------------------------
  # Common tags
  # ---------------------------------------------------------------------------
  # var.tags is merged first so module-managed tags below always win on
  # key conflicts and cannot be overridden by callers.
  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "backend-bootstrap"
    Component   = "terraform-backend"
  })
}
