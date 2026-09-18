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
# KMS Module — outputs.tf
###############################################################################

#------------------------------------------------------------------------------
# Key
#------------------------------------------------------------------------------
output "key_arn" {
  description = "ARN of the KMS key (primary or replica). `null` when `create = false`."
  value       = local.key_arn
}

output "key_id" {
  description = "Globally unique identifier of the KMS key. `null` when `create = false`."
  value       = local.key_id
}

output "key_policy" {
  description = "Rendered JSON key policy attached to the key. `null` when `create = false`."
  value       = one(data.aws_iam_policy_document.this[*].json)
}

#------------------------------------------------------------------------------
# Aliases
#------------------------------------------------------------------------------
output "aliases" {
  description = <<-EOT
    Map of aliases created, keyed by the input alias value. Each entry exposes
    `arn` and `name` (normalized to the `alias/...` form).
  EOT
  value = {
    for k, v in aws_kms_alias.this : k => {
      arn  = v.arn
      name = v.name
    }
  }
}

#------------------------------------------------------------------------------
# Grants
#------------------------------------------------------------------------------
output "grants" {
  description = "Map of grants created, keyed by the input grant key. Each entry exposes the grant `id` (unique per key) and `key_id`."
  value = {
    for k, v in aws_kms_grant.this : k => {
      id     = v.grant_id
      key_id = v.key_id
    }
  }
}

output "grant_tokens" {
  description = <<-EOT
    Map of grant tokens, keyed by the input grant key. A grant token allows a
    grantee to use the grant immediately, before eventual consistency has
    propagated. Marked sensitive because a token temporarily conveys the
    permissions of its grant to whoever holds it.
  EOT
  value       = { for k, v in aws_kms_grant.this : k => v.grant_token }
  sensitive   = true
}
