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
# AWS GuardDuty Module - Version Constraints
#
# Description:
#   Declares the Terraform CLI and provider version contract for this module.
#
# Constraint Policy (reusable module):
#   - Lower bounds are FEATURE-DRIVEN: they encode the minimum version that
#     supports every language construct and provider resource used here.
#   - Upper bounds are MAJOR-ONLY: they prevent silently adopting a breaking
#     major release, while still allowing consumers to receive minor/patch
#     fixes. Exact pinning belongs in the root module's .terraform.lock.hcl,
#     never in a shared module.
#   - No `provider` blocks are declared here. Provider configuration and
#     credentials/region/default_tags are the responsibility of the caller;
#     declaring them inside a module breaks multi-region and aliased usage.
#
# Terraform >= 1.5.0 rationale:
#   - >= 1.3.0 : object type `optional()` attributes with defaults, used by
#                every complex input in variables.tf.
#   - >= 1.4.0 : reliable multiple `validation` blocks per variable.
#   - >= 1.5.0 : `check` blocks, `import` blocks and stable nested-optional
#                defaults; chosen as the practical enterprise floor since all
#                supported CLI releases are >= 1.5.
#
# AWS provider >= 5.40.0 rationale:
#   - aws_guardduty_detector_feature (drift-free replacement for the
#     deprecated `datasources` block) and its `additional_configuration`
#     sub-feature blocks.
#   - aws_guardduty_organization_configuration_feature.
#   - aws_guardduty_organization_configuration.auto_enable_organization_members
#     (replaces the removed `auto_enable` argument).
#   - Stable RUNTIME_MONITORING agent-management sub-features.
#   Upper bound < 7.0.0 keeps v6.x compatible (v6 only removed the
#   `datasources` block, which this module never uses).
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 7.0.0"
    }
  }
}
