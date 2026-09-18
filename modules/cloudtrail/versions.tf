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
# AWS CloudTrail Module — Version Constraints
#
# Declares the minimum Terraform CLI version and the required providers.
#
# Constraint rationale:
#   - Terraform >= 1.3: required for `optional()` object type attributes with
#     defaults (used by `event_selectors` / `advanced_event_selectors`) and
#     the `startswith()` / `endswith()` functions used in variable validation.
#   - AWS provider ~> 5.0: the module targets the v5 resource schemas
#     (standalone `aws_s3_bucket_*` configuration resources) and reads
#     `data.aws_region.current.name`, which is deprecated in v6 in favor of
#     `.region`. The upper bound prevents an unreviewed major-version upgrade
#     from breaking the module; bump deliberately after migrating that
#     attribute.
#
# Convention:
#   Reusable modules declare *minimum* compatible versions and let the root
#   module (or a lockfile) pin exact versions. Only the provider's major
#   version is bounded here, since major releases contain breaking changes.
###############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
