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
# GitHub Actions OIDC Federation — Version Constraints
#
# This is a reusable child module, so it declares only minimum supported
# versions. Consuming root modules should control maximum versions and commit
# their dependency lock files.
###############################################################################

terraform {
  # Terraform 1.6 is the repository-wide minimum supported version.
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # AWS provider 5.81 made thumbprint_list optional for IAM OIDC providers.
      # main.tf relies on that behavior to avoid unnecessary TLS lookups.
      version = ">= 5.81.0"
    }
  }
}
