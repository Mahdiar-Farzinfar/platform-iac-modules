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
# Log Archive Bucket Module — versions.tf
#
# Description:
#   Declares the Terraform core and provider version constraints this module
#   is tested against. Kept in a dedicated file so tooling (terraform-docs,
#   tflint, Renovate/Dependabot) can locate and manage constraints easily.
#
# Constraint policy (reusable module, not a root module):
#   - Use range constraints (>= lower, < next-major), NOT exact pins.
#     Exact pins in a shared module force every consumer onto one version
#     and cause hard conflicts between modules. Version *pinning* belongs
#     in the root module / lockfile (.terraform.lock.hcl), not here.
#   - Lower bounds reflect actual feature usage (documented below), so the
#     constraint is honest rather than arbitrary.
#
# Notes:
#   - No provider blocks here: reusable modules must never configure
#     providers; they inherit them from the caller.
###############################################################################

terraform {
  # 1.5+ required for:
  #   - `check`/`import` era of Terraform not used, but 1.5 is the floor of
  #     currently maintained releases this module is CI-tested against.
  #   - Guarantees stable behavior of `validation` blocks and optional
  #     object attributes used across the module's variables.
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # 5.x floor justified by resources/arguments used in main.tf:
      #   - Standalone resources (aws_s3_bucket_versioning,
      #     aws_s3_bucket_server_side_encryption_configuration,
      #     aws_s3_bucket_lifecycle_configuration, ...) — provider >= 4.0.
      #   - `filter {}` block semantics in lifecycle configuration and
      #     BucketOwnerEnforced ownership controls stabilized in >= 4.9.
      #   - 5.0 chosen as floor because 4.x is EOL and no longer receives
      #     security patches; module CI runs against 5.x and 6.x.
      # Upper bound excludes the next major to protect consumers from
      # unreviewed breaking changes.
      version = ">= 5.0.0, < 7.0.0"
    }
  }
}
