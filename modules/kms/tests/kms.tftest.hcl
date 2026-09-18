# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# KMS Module — tests/kms.tftest.hcl
#
# Unit tests (no AWS credentials required). The AWS provider is mocked, so:
#   - run blocks use `command = plan` and assert on *configured* (known)
#     attributes: counts, argument values, policy statement blocks, tags.
#   - one `command = apply` run exercises output shapes against mocked
#     computed values.
#   - variable validation is exercised via `expect_failures`.
#
# Real-infrastructure verification (actual policy evaluation, replica
# propagation, grant tokens) belongs in tests/integration-test.go.
#
# Run:  terraform test
###############################################################################

# Offline provider: no credentials, no metadata/STS calls. Client-side data
# sources (aws_iam_policy_document) are still evaluated for real, so the key
# policy under test is the one the module actually renders.
provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "mock-access-key"
  secret_key                  = "mock-secret-key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

# Only the two API-backed data sources are stubbed.
override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111122223333"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

override_resource {
  target = aws_kms_key.this
  values = {
    region = "eu-wesd-12ab-34cd-56ef-1234567890ab"
    arn    = "arn:aws:kms:eu-west-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }
}

override_resource {
  target = aws_kms_replica_key.this
  values = {
    region = "eu-west-1"
    id     = "5678efab-56ef-78ab-90cd-5678901234cd"
    key_id = "5678efab-56ef-78ab-90cd-5678901234cd"
    arn    = "arn:aws:kms:eu-west-1:111122223333:key/5678efab-56ef-78ab-90cd-5678901234cd"
  }
}

override_resource {
  target = aws_kms_alias.this
  values = {
    region = "eu-west-1"
  }
}

override_resource {
  target = aws_kms_grant.this
  values = {
    region = "eu-west-1"
  }
}

#------------------------------------------------------------------------------
# Shared fixtures
#------------------------------------------------------------------------------
variables {
  description = "test key"
}

#------------------------------------------------------------------------------
# 1. Secure defaults
#------------------------------------------------------------------------------
run "defaults_create_primary_key_with_secure_settings" {
  command = plan

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "Exactly one primary key must be created with default inputs."
  }

  assert {
    condition     = length(aws_kms_replica_key.this) == 0
    error_message = "No replica key must be created when create_replica = false."
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation == true
    error_message = "Key rotation must be enabled by default (secure default)."
  }

  assert {
    condition     = aws_kms_key.this[0].deletion_window_in_days == 30
    error_message = "Deletion window must default to the maximum of 30 days."
  }

  assert {
    condition     = aws_kms_key.this[0].bypass_policy_lockout_safety_check == false
    error_message = "Policy lockout safety check must not be bypassed by default."
  }

  assert {
    condition     = aws_kms_key.this[0].customer_master_key_spec == "SYMMETRIC_DEFAULT"
    error_message = "Key spec must default to SYMMETRIC_DEFAULT."
  }

  assert {
    condition     = aws_kms_key.this[0].key_usage == "ENCRYPT_DECRYPT"
    error_message = "Key usage must default to ENCRYPT_DECRYPT."
  }

  assert {
    condition     = aws_kms_key.this[0].multi_region == false
    error_message = "multi_region must default to false."
  }

  assert {
    condition     = length(aws_kms_alias.this) == 0 && length(aws_kms_grant.this) == 0
    error_message = "No aliases or grants must be created when none are provided."
  }
}

#------------------------------------------------------------------------------
# 2. Key policy composition
#------------------------------------------------------------------------------
run "key_policy_includes_root_access" {
  command = plan

  assert {
    condition = can(regex(
      "\"Sid\": \"EnableRootAccountAccess\"",
      data.aws_iam_policy_document.this[0].json
    ))
    error_message = "Key policy must include the EnableRootAccountAccess statement."
  }

  assert {
    condition = can(regex(
      "arn:aws:iam::111122223333:root",
      data.aws_iam_policy_document.this[0].json
    ))
    error_message = "Root access must be granted to the current account ID (mocked)."
  }
}

run "key_policy_includes_administrators_and_users" {
  command = plan

  variables {
    key_administrators = ["arn:aws:iam::111122223333:role/admin"]
    key_users          = ["arn:aws:iam::111122223333:role/user"]
  }

  assert {
    condition = can(regex(
      "\"Sid\": \"KeyAdministration\"",
      data.aws_iam_policy_document.this[0].json
    ))
    error_message = "Key policy must include KeyAdministration when key_administrators is provided."
  }

  assert {
    condition = can(regex(
      "\"Sid\": \"KeyUsage\"",
      data.aws_iam_policy_document.this[0].json
    ))
    error_message = "Key policy must include KeyUsage when key_users is provided."
  }
}

#------------------------------------------------------------------------------
# 3. Aliases and Grants
#------------------------------------------------------------------------------
run "aliases_are_normalized_and_attached" {
  command = plan

  variables {
    aliases = ["app", "alias/db"]
  }

  assert {
    condition     = length(aws_kms_alias.this) == 2
    error_message = "Two aliases must be created."
  }

  assert {
    condition     = aws_kms_alias.this["app"].name == "alias/app"
    error_message = "Bare alias name 'app' must be normalized to 'alias/app'."
  }

  assert {
    condition     = aws_kms_alias.this["alias/db"].name == "alias/db"
    error_message = "Already-prefixed alias name 'alias/db' must not be double-prefixed."
  }
}

run "grants_are_configured_correctly" {
  command = plan

  variables {
    grants = {
      test-grant = {
        grantee_principal = "arn:aws:iam::111122223333:role/service"
        operations        = ["Encrypt", "Decrypt"]
        constraints = {
          encryption_context_equals = { "Env" = "Prod" }
        }
      }
    }
  }

  assert {
    condition     = length(aws_kms_grant.this) == 1
    error_message = "Exactly one grant must be created."
  }

  assert {
    condition     = aws_kms_grant.this["test-grant"].name == "test-grant"
    error_message = "Grant name must fall back to the map key when not explicitly set."
  }
}

#------------------------------------------------------------------------------
# 4. Multi-Region Replicas
#------------------------------------------------------------------------------
run "create_replica_disables_primary_and_uses_replica_resource" {
  command = plan

  variables {
    create_replica  = true
    primary_key_arn = "arn:aws:kms:us-east-1:111122223333:key/mrk-0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "Primary key resource must not exist when create_replica = true."
  }

  assert {
    condition     = length(aws_kms_replica_key.this) == 1
    error_message = "Replica key resource must exist when create_replica = true."
  }

  assert {
    condition     = aws_kms_replica_key.this[0].primary_key_arn == var.primary_key_arn
    error_message = "Replica must point to the provided primary_key_arn."
  }
}

#------------------------------------------------------------------------------
# 5. Variable Validation
#------------------------------------------------------------------------------
run "invalid_alias_prefix_is_rejected" {
  command = plan

  variables {
    aliases = ["aws/s3"]
  }

  expect_failures = [
    var.aliases
  ]
}

run "invalid_rotation_period_is_rejected" {
  command = plan

  variables {
    rotation_period_in_days = 30 # Min is 90
  }

  expect_failures = [
    var.rotation_period_in_days
  ]
}

run "simultaneous_grant_constraints_are_rejected" {
  command = plan

  variables {
    grants = {
      bad = {
        grantee_principal = "arn:aws:iam::111122223333:role/user"
        operations        = ["Encrypt"]
        constraints = {
          encryption_context_equals = { "A" = "1" }
          encryption_context_subset = { "B" = "2" }
        }
      }
    }
  }

  expect_failures = [
    var.grants
  ]
}

#------------------------------------------------------------------------------
# 6. Outputs (Mocked Apply)
#------------------------------------------------------------------------------
run "outputs_are_consistent" {
  command = apply

  variables {
    aliases = ["app"]
  }

  assert {
    condition     = output.key_arn != null && output.key_id != null
    error_message = "Key ARN and ID must be exported."
  }

  assert {
    condition     = output.aliases["app"].name == "alias/app"
    error_message = "Aliases output must contain normalized names."
  }
}

#------------------------------------------------------------------------------
# 7. Disabling the Module
#------------------------------------------------------------------------------
run "module_can_be_disabled" {
  command = plan

  variables {
    create = false
  }

  assert {
    condition     = length(aws_kms_key.this) == 0 && length(aws_kms_replica_key.this) == 0 && length(aws_kms_alias.this) == 0
    error_message = "No resources must be created when create = false."
  }

  assert {
    condition     = output.key_arn == null
    error_message = "Key ARN output must be null when disabled."
  }
}
