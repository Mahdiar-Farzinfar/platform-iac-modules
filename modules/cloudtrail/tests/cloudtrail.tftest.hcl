# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# Native Terraform Tests — AWS CloudTrail Module
#
# Strategy:
#   - Unit tests only. Every run uses `command = plan` against a mocked AWS
#     provider: no credentials, no cost, no real infrastructure, safe for CI
#     on every commit.
#   - Assertions target values KNOWN AT PLAN TIME: conditional resource
#     counts, literal attributes, and variable-derived settings. Computed
#     attributes (ARNs, bucket domain names) are intentionally not asserted —
#     under a mock provider they are unknown or synthetic.
#   - Input `validation` blocks are exercised with `expect_failures`, so a
#     regression that loosens a guardrail fails the suite.
#
# Runtime requirement:
#   `terraform test` requires Terraform >= 1.6 and `mock_provider` requires
#   >= 1.7. This constrains CI only; module consumers remain on >= 1.3.0.
#
# Run from the module root:
#   terraform init && terraform test
###############################################################################

mock_provider "aws" {
  # Deterministic identity data so derived names (bucket name, ARNs built in
  # locals) are stable across machines and CI runs.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

override_data {
  target = data.aws_iam_policy_document.cloudwatch_logs_assume

  values = {
    json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
      }]
    })
  }
}

# Baseline inputs shared by every run. Individual runs override as needed.
variables {
  name       = "tftest"
  trail_name = "tftest-trail"
}

#------------------------------------------------------------------------------
# 1. Secure defaults — the flagship contract of the module
#------------------------------------------------------------------------------
run "defaults_create_full_secure_stack" {
  command = plan

  assert {
    condition     = length(aws_kms_key.cloudtrail) == 1
    error_message = "A CMK must be created by default (create_kms_key = true)."
  }

  assert {
    condition     = aws_kms_key.cloudtrail[0].enable_key_rotation == true
    error_message = "The module-managed CMK must have automatic rotation enabled."
  }

  assert {
    condition     = aws_kms_key.cloudtrail[0].deletion_window_in_days == 30
    error_message = "The default KMS deletion window must be the maximum safety net of 30 days."
  }

  assert {
    condition     = length(aws_kms_alias.cloudtrail) == 1
    error_message = "A KMS alias must accompany the module-managed CMK."
  }

  assert {
    condition     = length(aws_s3_bucket.cloudtrail) == 1
    error_message = "The log bucket must be created by default (create_s3_bucket = true)."
  }

  assert {
    condition     = aws_s3_bucket.cloudtrail[0].force_destroy == false
    error_message = "force_destroy must default to false — audit logs must not be trivially destructible."
  }

  assert {
    condition     = aws_s3_bucket_versioning.cloudtrail[0].versioning_configuration[0].status == "Enabled"
    error_message = "Bucket versioning must be enabled on the log bucket."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.cloudtrail[0].block_public_acls == true &&
      aws_s3_bucket_public_access_block.cloudtrail[0].block_public_policy == true &&
      aws_s3_bucket_public_access_block.cloudtrail[0].ignore_public_acls == true &&
      aws_s3_bucket_public_access_block.cloudtrail[0].restrict_public_buckets == true
    )
    error_message = "All four public access block settings must be enabled on the log bucket."
  }

  assert {
    condition     = length(aws_s3_bucket_policy.cloudtrail) == 1
    error_message = "A bucket policy (ACL check, write, TLS-only) must be attached to the module-managed bucket."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.cloudtrail) == 1
    error_message = "The lifecycle policy must be enabled by default."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.cloudtrail[0].rule[0].expiration[0].days == 365
    error_message = "Default log expiration must be 365 days."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.cloudtrail) == 1
    error_message = "CloudWatch Logs delivery must be enabled by default."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cloudtrail[0].retention_in_days == 365
    error_message = "Default CloudWatch Logs retention must be 365 days."
  }

  assert {
    condition     = aws_cloudtrail.this.enable_log_file_validation == true
    error_message = "Log file validation is hardcoded on and must never regress."
  }

  assert {
    condition     = aws_cloudtrail.this.is_multi_region_trail == true
    error_message = "The trail must be multi-region by default (CIS 3.1)."
  }

  assert {
    condition     = aws_cloudtrail.this.include_global_service_events == true
    error_message = "Global service events (IAM, STS) must be captured by default."
  }

  assert {
    condition     = aws_cloudtrail.this.s3_key_prefix == "cloudtrail"
    error_message = "The default S3 key prefix must be 'cloudtrail'."
  }
}

#------------------------------------------------------------------------------
# 2. Feature flags — each conditional subsystem can be cleanly disabled
#------------------------------------------------------------------------------
run "kms_disabled_falls_back_without_cmk" {
  command = plan

  variables {
    create_kms_key = false
  }

  assert {
    condition     = length(aws_kms_key.cloudtrail) == 0 && length(aws_kms_alias.cloudtrail) == 0
    error_message = "No CMK or alias may be created when create_kms_key = false."
  }

  assert {
    condition     = aws_cloudtrail.this.kms_key_id == null
    error_message = "The trail must not reference a KMS key when none is created or supplied."
  }
}

run "byo_kms_key_is_passed_through" {
  command = plan

  variables {
    create_kms_key = false
    kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = length(aws_kms_key.cloudtrail) == 0
    error_message = "No CMK may be created when an external key is supplied."
  }

  assert {
    condition     = aws_cloudtrail.this.kms_key_id == var.kms_key_arn
    error_message = "The trail must encrypt with the caller-supplied KMS key ARN."
  }
}

run "external_bucket_is_honored" {
  command = plan

  variables {
    create_s3_bucket = false
    s3_bucket_name   = "preexisting-audit-bucket"
  }

  assert {
    condition     = length(aws_s3_bucket.cloudtrail) == 0 && length(aws_s3_bucket_policy.cloudtrail) == 0
    error_message = "No bucket or bucket policy may be created when create_s3_bucket = false."
  }

  assert {
    condition     = aws_cloudtrail.this.s3_bucket_name == "preexisting-audit-bucket"
    error_message = "The trail must deliver to the caller-supplied bucket."
  }

  assert {
    condition     = output.s3_bucket_id == "preexisting-audit-bucket"
    error_message = "s3_bucket_id must surface the external bucket name, not null."
  }
}

run "cloudwatch_logs_disabled" {
  command = plan

  variables {
    enable_cloudwatch_logs = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.cloudtrail) == 0
    error_message = "No log group may be created when enable_cloudwatch_logs = false."
  }

  assert {
    condition     = aws_cloudtrail.this.cloud_watch_logs_group_arn == null && aws_cloudtrail.this.cloud_watch_logs_role_arn == null
    error_message = "The trail must not wire CloudWatch Logs delivery when it is disabled."
  }
}

run "lifecycle_can_be_disabled_independently" {
  command = plan

  variables {
    s3_lifecycle_enabled = false
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.cloudtrail) == 1
    error_message = "The lifecycle configuration must remain present when the module-managed bucket exists."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.cloudtrail[0].rule[0].status == "Disabled"
    error_message = "The lifecycle rule must be disabled when s3_lifecycle_enabled = false."
  }

  assert {
    condition     = length(aws_s3_bucket.cloudtrail) == 1
    error_message = "Disabling the lifecycle policy must not disable the bucket itself."
  }
}

#------------------------------------------------------------------------------
# 3. Event filtering — dynamic blocks render from structured inputs
#------------------------------------------------------------------------------
run "event_selectors_are_rendered" {
  command = plan

  variables {
    event_selectors = [{
      read_write_type           = "WriteOnly"
      include_management_events = true
      data_resources = [{
        type   = "AWS::S3::Object"
        values = ["arn:aws:s3"]
      }]
    }]
  }

  assert {
    condition     = length(aws_cloudtrail.this.event_selector) == 1
    error_message = "Exactly one event_selector block must be rendered."
  }

  assert {
    condition     = aws_cloudtrail.this.event_selector[0].read_write_type == "WriteOnly"
    error_message = "read_write_type must pass through to the rendered event selector."
  }
}

run "insight_selectors_are_rendered" {
  command = plan

  variables {
    insight_selectors = ["ApiCallRateInsight", "ApiErrorRateInsight"]
  }

  assert {
    condition     = length(aws_cloudtrail.this.insight_selector) == 2
    error_message = "Both requested insight selectors must be rendered."
  }
}

#------------------------------------------------------------------------------
# 4. Input guardrails — validation blocks must fail fast at plan time
#------------------------------------------------------------------------------
run "rejects_invalid_trail_name" {
  command = plan

  variables {
    trail_name = "-starts-with-hyphen"
  }

  expect_failures = [var.trail_name]
}

run "rejects_out_of_range_kms_deletion_window" {
  command = plan

  variables {
    kms_key_deletion_window = 5
  }

  expect_failures = [var.kms_key_deletion_window]
}

run "rejects_malformed_kms_key_arn" {
  command = plan

  variables {
    create_kms_key = false
    kms_key_arn    = "not-an-arn"
  }

  expect_failures = [var.kms_key_arn]
}

run "rejects_unsupported_log_retention" {
  command = plan

  variables {
    cloudwatch_logs_retention_days = 42
  }

  expect_failures = [var.cloudwatch_logs_retention_days]
}

run "rejects_slash_wrapped_s3_key_prefix" {
  command = plan

  variables {
    s3_key_prefix = "/logs/"
  }

  expect_failures = [var.s3_key_prefix]
}

run "rejects_ia_transition_below_aws_minimum" {
  command = plan

  variables {
    s3_transition_to_ia_days = 10
  }

  expect_failures = [var.s3_transition_to_ia_days]
}

run "rejects_unknown_insight_selector" {
  command = plan

  variables {
    insight_selectors = ["NotARealInsight"]
  }

  expect_failures = [var.insight_selectors]
}
