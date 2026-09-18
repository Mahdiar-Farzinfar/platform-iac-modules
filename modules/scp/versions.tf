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
# SCP Module — Version Constraints
#
# Pins the minimum Terraform CLI version and the AWS provider version range
# required by this module. Callers inherit these constraints automatically;
# a root module that already pins a compatible range takes precedence.
#
# Terraform floor rationale:
#   >= 1.5 — check blocks (locals.tf mutual-exclusivity assertion)
#            optional() object attributes (variables.tf statements type)
#            lifecycle preconditions (main.tf SCP and attachment guards)
#
# AWS provider floor rationale:
#   >= 5.0 — aws_organizations_policy and aws_organizations_policy_attachment
#            have been stable across the 4.x and 5.x lines; 5.0 is chosen as
#            the floor to benefit from provider-side validation improvements
#            and to avoid carrying compatibility shims for the 4.x schema.
#   < 6.0  — Upper bound guards against silent breaking changes in a future
#            major provider release. Update after validating against 6.x.
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}
