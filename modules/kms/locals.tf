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
# KMS Module — locals.tf
#
# Derives a single key_id / key_arn regardless of whether this module
# instance manages a primary key (aws_kms_key) or a multi-Region replica
# (aws_kms_replica_key). Exactly one of the two resources exists when
# var.create is true; both lists are empty when var.create is false, in
# which case one() yields null and dependent resources are not created.
###############################################################################

locals {
  #----------------------------------------------------------------------------
  # Key identity (primary XOR replica)
  #----------------------------------------------------------------------------
  # one() is preferred over try(...[0]...) chains: it returns the single
  # element, null for an empty collection, and errors loudly if both
  # resources ever exist at once (an invariant violation worth failing on).
  key_id = one(concat(
    aws_kms_key.this[*].key_id,
    aws_kms_replica_key.this[*].key_id,
  ))

  key_arn = one(concat(
    aws_kms_key.this[*].arn,
    aws_kms_replica_key.this[*].arn,
  ))

  #----------------------------------------------------------------------------
  # Tags
  #----------------------------------------------------------------------------
  # Module-identifying tags are applied first so caller-supplied tags win on
  # collision. Account-/org-wide tags (Environment, CostCenter, Owner, ...)
  # belong in the provider's default_tags, not here.
  module_tags = {
    "terraform-module" = "kms"
  }

  tags = merge(local.module_tags, var.tags)
}
