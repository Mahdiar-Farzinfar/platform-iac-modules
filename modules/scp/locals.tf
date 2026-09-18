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
# SCP Module — Local Values
#
# Resolves the effective policy document from the two mutually exclusive
# inputs and exposes it as local.policy_content for the resources in main.tf:
#   - var.policy_content : a raw, pre-rendered JSON policy document
#   - var.statements      : structured statements rendered here to JSON
#
# Rendering happens here (not in the resource) so that the document is a
# single, canonical value that main.tf's preconditions can validate for the
# 5120-character limit and JSON validity.
###############################################################################

locals {
  # Which of the two input sources the caller provided. A raw document is
  # considered "provided" when non-null and non-empty after trimming; the
  # statements list is "provided" when it contains at least one statement.
  raw_provided        = var.policy_content != null ? trimspace(var.policy_content) != "" : false
  statements_provided = length(var.statements) > 0

  # Render var.statements into a standard IAM policy document. Optional
  # attributes (sid, condition) are only emitted when set, keeping the
  # rendered document compact and free of null/empty noise. The Version is
  # fixed to the current IAM policy grammar version.
  rendered_statements = [
    for s in var.statements : merge(
      {
        Effect   = s.effect
        Action   = s.actions
        Resource = s.resources
      },
      s.sid == null ? {} : { Sid = s.sid },
      length(s.condition) == 0 ? {} : { Condition = s.condition },
    )
  ]

  rendered_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.rendered_statements
  })

  # The effective policy document. Prefer the raw JSON document when supplied;
  # otherwise fall back to the rendered statements. When neither is provided
  # (e.g. a placeholder/disabled module), fall back to a syntactically valid
  # empty document so downstream preconditions produce clear, targeted errors
  # rather than a type error on a null value.
  policy_content = local.raw_provided ? var.policy_content : local.rendered_policy
}

#------------------------------------------------------------------------------
# Cross-variable input validation
#
# These checks span multiple variables and therefore cannot live in a single
# variable's validation block. They surface as plan-time diagnostics.
#------------------------------------------------------------------------------

# Exactly one policy source must be provided when the module is active. This
# prevents ambiguous configuration where both a raw document and structured
# statements are set, or where neither is set while create is true.
check "policy_source_is_unambiguous" {
  assert {
    condition = (
      !var.create ||
      (local.raw_provided != local.statements_provided)
    )
    error_message = <<-EOT
      Exactly one policy source must be provided when create = true:
      set either var.policy_content (raw JSON) or var.statements (structured),
      but not both and not neither.
    EOT
  }
}
