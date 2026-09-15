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
# Backend Bootstrap — Version Constraints
#
# NOTE: Intentionally NO `backend` block here — this module bootstraps the
# remote-state infrastructure itself and must first apply with local state.
###############################################################################

terraform {
  # Terraform 1.6+ is required for the features used by this module.
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # AWS provider 5.70+ supports the S3 lifecycle configuration and
      # DynamoDB deletion protection used by this module.
      version = ">= 5.70.0, < 7.0.0"
    }
  }
}
