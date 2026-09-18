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
# Log Archive Bucket Module — locals.tf
#
# Description:
#   Computed values shared across the module. Deliberately minimal: only
#   values that are (a) referenced from more than one place, or (b) derived
#   through normalization/merging logic that should not be repeated inline.
#
# Contents:
#   - bucket_name : normalized bucket name consumed by aws_s3_bucket and
#                   aws_s3_bucket_logging (target_prefix).
#   - tags        : caller tags merged over module-provenance defaults.
#
# Conventions:
#   - No locals that merely alias a variable (adds indirection, not value).
#   - Tag merge order: caller-supplied tags take precedence over module
#     defaults, so environments can override provenance metadata if their
#     tagging policy requires it.
###############################################################################

locals {
  # ---------------------------------------------------------------------------
  # Naming
  # ---------------------------------------------------------------------------
  # S3 bucket names must be lowercase; trim guards against copy-paste
  # whitespace from tfvars/CI inputs. The regex validation on
  # var.bucket_name in variables.tf runs on the raw input, so normalization
  # here is a belt-and-braces defense, not the primary gate.
  bucket_name = lower(trimspace(var.bucket_name))

  # ---------------------------------------------------------------------------
  # Tagging
  # ---------------------------------------------------------------------------
  # Provenance defaults make every resource traceable to this module in
  # cost-allocation reports and IAM/ABAC policies without requiring callers
  # to remember them.
  module_tags = {
    ManagedBy          = "terraform"
    TerraformModule    = "log-archive-bucket"
    DataClassification = "log-archive"
  }

  # Caller tags win on key collision (rightmost argument to merge()
  # takes precedence).
  tags = merge(local.module_tags, var.tags)
}
