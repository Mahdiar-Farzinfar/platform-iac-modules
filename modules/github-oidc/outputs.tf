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
# GitHub Actions OIDC Federation — Outputs
#
# Exposes the provider and role identifiers needed by calling configurations,
# GitHub Actions workflows, IAM policies, and operational tooling.
###############################################################################

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider created by this module or supplied by the caller; null when neither is configured."
  value       = local.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "Issuer URL of the GitHub Actions OIDC provider."
  value       = local.github_oidc_issuer_url
}

output "role_arns" {
  description = "IAM role ARNs keyed by the corresponding roles map key; use these values with GitHub Actions role-to-assume."
  value = {
    for role_key, role in aws_iam_role.this :
    role_key => role.arn
  }
}

output "role_names" {
  description = "IAM role names keyed by the corresponding roles map key."
  value = {
    for role_key, role in aws_iam_role.this :
    role_key => role.name
  }
}
