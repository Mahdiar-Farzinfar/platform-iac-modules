# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# SCP Module — Native Terraform Tests (terraform test)
#
# Validates the module's public contract using the built-in test harness
# (Terraform >= 1.6). Tests are layered so the fast, side-effect-free checks
# run first and the (mocked) apply-time checks run last:
#
#   1. plan-only, provider mocked — assert rendered content, tag merging,
#      attachment fan-out, and null-safety of outputs. No AWS calls.
#   2. plan-only, expect_failures — assert that variable validations and
#      resource preconditions reject bad input as designed.
#
# Why mock the provider:
#   AWS Organizations SCPs are org-wide, management-account-only resources
#   with real governance blast radius. Mocking lets the full plan graph
#   (including the aws_organizations_policy_attachment fan-out and the
#   count/for_each addressing) be exercised deterministically in CI with no
#   credentials, no organization, and no cost.
#
# Conventions:
#   - command = plan keeps every run hermetic; no resources are created.
#   - Each run overrides only the variables it exercises; the module's own
#     defaults are relied upon everywhere else.
#   - expect_failures targets the specific validation/precondition address so
#     a test fails loudly if a guardrail is silently removed or relaxed.
#
# Run:
#   terraform test
###############################################################################

#------------------------------------------------------------------------------
# Global mock provider
#
# Supplies deterministic values for the computed attributes the module reads
# back (policy id/arn/aws_managed and the attachment policy_id/target_id) so
# plan can fully resolve outputs without contacting AWS.
#------------------------------------------------------------------------------
mock_provider "aws" {
  mock_resource "aws_organizations_policy" {
    defaults = {
      id          = "p-mocktest0"
      arn         = "arn:aws:organizations::123456789012:policy/o-mockorg/service_control_policy/p-mocktest0"
      aws_managed = false
    }
  }
}

#------------------------------------------------------------------------------
# 1. Happy path — structured statements rendered and attached
#------------------------------------------------------------------------------
run "renders_structured_statements_and_attaches_to_targets" {
  command = plan

  variables {
    name        = "baseline-guardrails"
    description = "Deny leaving org and disabling CloudTrail."

    statements = [
      {
        sid       = "DenyLeaveOrganization"
        effect    = "Deny"
        actions   = ["organizations:LeaveOrganization"]
        resources = ["*"]
      },
      {
        sid    = "DenyDisableCloudTrail"
        effect = "Deny"
        actions = [
          "cloudtrail:StopLogging",
          "cloudtrail:DeleteTrail",
          "cloudtrail:UpdateTrail",
        ]
        resources = ["*"]
      },
    ]

    target_ids = ["r-abc1", "ou-abc1-12345678", "123456789012"]

    tags = {
      Environment = "all"
      Purpose     = "guardrail"
    }
  }

  # The policy resource exists (count = 1) and carries the requested name.
  assert {
    condition     = aws_organizations_policy.this[0].name == "baseline-guardrails"
    error_message = "Policy name did not match the requested input."
  }

  # Rendered content is valid JSON and a proper 2012-10-17 policy document.
  assert {
    condition     = can(jsondecode(local.policy_content))
    error_message = "Rendered policy_content is not valid JSON."
  }

  assert {
    condition     = jsondecode(local.policy_content).Version == "2012-10-17"
    error_message = "Rendered policy document is missing the 2012-10-17 Version field."
  }

  # Both statements survive rendering.
  assert {
    condition     = length(jsondecode(local.policy_content).Statement) == 2
    error_message = "Expected exactly 2 rendered statements."
  }

  # Module-managed ownership tags are merged onto caller tags.
  assert {
    condition = (
      aws_organizations_policy.this[0].tags["ManagedBy"] == "terraform" &&
      aws_organizations_policy.this[0].tags["Module"] == "scp" &&
      aws_organizations_policy.this[0].tags["Environment"] == "all"
    )
    error_message = "Module ownership tags were not merged with caller tags as expected."
  }

  # One attachment per unique target, keyed by target ID.
  assert {
    condition     = length(aws_organizations_policy_attachment.this) == 3
    error_message = "Expected one attachment per unique target ID (3)."
  }

  # Output surfaces the exact set of attached targets.
  assert {
    condition = toset(output.target_ids) == toset([
      "r-abc1", "ou-abc1-12345678", "123456789012",
    ])
    error_message = "output.target_ids did not reflect the configured targets."
  }
}

#------------------------------------------------------------------------------
# 2. Raw JSON policy_content is used verbatim
#------------------------------------------------------------------------------
run "accepts_raw_json_policy_content" {
  command = plan

  variables {
    name = "raw-json-policy"
    policy_content = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "DenyAllOutsideRegion"
          Effect   = "Deny"
          Action   = "*"
          Resource = "*"
        },
      ]
    })
    target_ids = ["r-abc1"]
  }

  # The raw document flows through unchanged to the resolved content.
  assert {
    condition     = jsondecode(local.policy_content).Statement[0].Sid == "DenyAllOutsideRegion"
    error_message = "Raw policy_content was not passed through verbatim."
  }
}

#------------------------------------------------------------------------------
# 3. Duplicate target IDs collapse to a single attachment
#------------------------------------------------------------------------------
run "deduplicates_target_ids" {
  command = plan

  variables {
    name           = "dedupe-targets"
    policy_content = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    target_ids     = ["r-abc1", "r-abc1", "r-abc1"]
  }

  # toset() in main.tf collapses the three identical entries to one instance.
  assert {
    condition     = length(aws_organizations_policy_attachment.this) == 1
    error_message = "Duplicate target IDs were not de-duplicated to a single attachment."
  }
}

#------------------------------------------------------------------------------
# 4. create = false produces zero resources and null-safe outputs
#------------------------------------------------------------------------------
run "create_false_produces_no_resources" {
  command = plan

  variables {
    create         = false
    name           = "disabled-policy"
    policy_content = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    target_ids     = ["r-abc1", "ou-abc1-12345678"]
  }

  # No policy instance.
  assert {
    condition     = length(aws_organizations_policy.this) == 0
    error_message = "Policy resource was created despite create = false."
  }

  # No attachments.
  assert {
    condition     = length(aws_organizations_policy_attachment.this) == 0
    error_message = "Attachments were created despite create = false."
  }

  # Scalar outputs are null, collection outputs are empty.
  assert {
    condition     = output.id == null && output.arn == null && output.name == null
    error_message = "Scalar outputs must be null when create = false."
  }

  assert {
    condition     = length(output.target_ids) == 0 && length(output.attachments) == 0
    error_message = "Collection outputs must be empty when create = false."
  }
}

#------------------------------------------------------------------------------
# 5. Negative — invalid target ID fails variable validation
#------------------------------------------------------------------------------
run "rejects_invalid_target_id" {
  command = plan

  variables {
    name           = "bad-target"
    policy_content = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    target_ids     = ["not-a-valid-target"]
  }

  expect_failures = [
    var.target_ids,
  ]
}

#------------------------------------------------------------------------------
# 6. Negative — invalid statement effect fails variable validation
#------------------------------------------------------------------------------
run "rejects_invalid_statement_effect" {
  command = plan

  variables {
    name = "bad-effect"
    statements = [
      {
        sid       = "BadEffect"
        effect    = "Permit" # not Allow/Deny
        actions   = ["*"]
        resources = ["*"]
      },
    ]
  }

  expect_failures = [
    var.statements,
  ]
}

#------------------------------------------------------------------------------
# 7. Negative — statement with no actions fails variable validation
#------------------------------------------------------------------------------
run "rejects_statement_without_actions" {
  command = plan

  variables {
    name = "no-actions"
    statements = [
      {
        effect    = "Deny"
        actions   = []
        resources = ["*"]
      },
    ]
  }

  expect_failures = [
    var.statements,
  ]
}

#------------------------------------------------------------------------------
# 8. Negative — malformed raw JSON fails variable validation
#------------------------------------------------------------------------------
run "rejects_malformed_policy_content" {
  command = plan

  variables {
    name           = "bad-json"
    policy_content = "{ this is not valid json"
    target_ids     = ["r-abc1"]
  }

  expect_failures = [
    var.policy_content,
  ]
}

#------------------------------------------------------------------------------
# 9. Negative — oversized document trips the 5120-char precondition
#------------------------------------------------------------------------------
run "rejects_oversized_policy_document" {
  command = plan

  variables {
    name = "too-large"
    # A single statement whose resource list exceeds the 5120-character SCP
    # limit once rendered. Passes JSON/variable validation but must fail the
    # resource precondition in main.tf.
    statements = [
      {
        sid       = "Oversized"
        effect    = "Deny"
        actions   = ["*"]
        resources = [for i in range(400) : "arn:aws:s3:::bucket-name-padding-${i}"]
      },
    ]
    target_ids = ["r-abc1"]
  }

  expect_failures = [
    aws_organizations_policy.this,
  ]
}

#------------------------------------------------------------------------------
# 10. Negative — SCP name over 128 characters fails variable validation
#------------------------------------------------------------------------------
run "rejects_overlong_name" {
  command = plan

  variables {
    # 129 characters — one over the documented AWS maximum.
    name           = "a-very-long-scp-name-that-deliberately-exceeds-the-one-hundred-and-twenty-eight-character-maximum-allowed-by-aws-organizations-xx"
    policy_content = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    target_ids     = ["r-abc1"]
  }

  expect_failures = [
    var.name,
  ]
}
