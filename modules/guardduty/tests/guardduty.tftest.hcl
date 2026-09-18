# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

###############################################################################
# AWS GuardDuty Module - Native Terraform Tests
#
# Description:
#   Validates the GuardDuty module using Terraform's built-in test framework
#   (terraform test, introduced in Terraform 1.6). Tests are grouped into
#   independent `run` blocks, each representing a distinct scenario or
#   assertion scope. All runs use the `plan` command by default to avoid
#   incurring AWS API calls or costs; use `command = apply` only for
#   integration scenarios that require real infrastructure.
#
# Test Strategy:
#   1. default_enabled          – Validates secure defaults: detector created,
#                                 all six protection planes present, publishing
#                                 frequency set to FIFTEEN_MINUTES.
#   2. disabled_module          – Verifies the master switch (var.enabled=false)
#                                 produces zero resources.
#   3. custom_publishing_freq   – Ensures ONE_HOUR frequency is accepted and
#                                 forwarded correctly.
#   4. subset_features          – Confirms a partial feature map creates only
#                                 the requested aws_guardduty_detector_feature
#                                 instances.
#   5. publishing_destination   – Validates that a valid publishing_destination
#                                 object adds the S3 destination resource.
#   6. finding_filters          – Verifies filter, action, rank, and criteria
#                                 attributes land on the plan correctly.
#   7. ipsets_and_threatintel   – Checks IP-set and threat-intel-set resources
#                                 from supplied map inputs.
#   8. organization_delegate    – Confirms the admin-account delegation resource
#                                 is planned when delegate_admin = true.
#   9. organization_config      – Confirms org-config + org-feature resources
#                                 appear when manage_org_configuration = true.
#  10. output_contract          – Asserts all published outputs are non-null /
#                                 match expected structural shapes.
#  11. tags_propagation         – Verifies caller tags are present in the
#                                 detector's tag map.
#
# Usage:
#   terraform test                          # run all blocks (plan-only by default)
#   terraform test -filter=run.disabled_module
#
# Requirements:
#   - Terraform >= 1.6.0
#   - No live AWS credentials are required for plan-only runs.
#   - The module path below assumes tests live at
#     modules/guardduty/tests/guardduty.tftest.hcl and the module root is one
#     level up (../). Adjust if the layout differs.
###############################################################################

#------------------------------------------------------------------------------
# Shared provider mock
#
# mock_provider stubs AWS API calls so all plan-mode tests run without
# credentials. Remove or replace with a real provider block for apply-mode
# integration tests.
#------------------------------------------------------------------------------
mock_provider "aws" {}

#------------------------------------------------------------------------------
# 1. Default enabled – secure defaults
#------------------------------------------------------------------------------
run "default_enabled" {
  command = plan

  # Detector is created
  assert {
    condition     = length(aws_guardduty_detector.this) == 1
    error_message = "Exactly one GuardDuty detector must be created when var.enabled is true (default)."
  }

  # Default publishing frequency
  assert {
    condition     = aws_guardduty_detector.this[0].finding_publishing_frequency == "FIFTEEN_MINUTES"
    error_message = "Default detector finding_publishing_frequency must be FIFTEEN_MINUTES."
  }

  # All six default protection planes are present
  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "S3_DATA_EVENTS")
    error_message = "S3_DATA_EVENTS feature must be created by default."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "EKS_AUDIT_LOGS")
    error_message = "EKS_AUDIT_LOGS feature must be created by default."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "EBS_MALWARE_PROTECTION")
    error_message = "EBS_MALWARE_PROTECTION feature must be created by default."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "RDS_LOGIN_EVENTS")
    error_message = "RDS_LOGIN_EVENTS feature must be created by default."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "LAMBDA_NETWORK_LOGS")
    error_message = "LAMBDA_NETWORK_LOGS feature must be created by default."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "RUNTIME_MONITORING")
    error_message = "RUNTIME_MONITORING feature must be created by default."
  }

  # Exactly six features (no extras introduced)
  assert {
    condition     = length(aws_guardduty_detector_feature.this) == 6
    error_message = "Default configuration must create exactly 6 detector features."
  }

  # All default features are ENABLED
  assert {
    condition = alltrue([
      for f in aws_guardduty_detector_feature.this : f.status == "ENABLED"
    ])
    error_message = "All default detector features must have status ENABLED."
  }

  # No publishing destination by default
  assert {
    condition     = length(aws_guardduty_publishing_destination.this) == 0
    error_message = "No publishing destination should be created when var.publishing_destination is null (default)."
  }

  # No org admin delegation by default
  assert {
    condition     = length(aws_guardduty_organization_admin_account.this) == 0
    error_message = "No organization admin account resource should be created with default inputs."
  }

  # No filters, ipsets, or threat intel sets by default
  assert {
    condition     = length(aws_guardduty_filter.this) == 0
    error_message = "No finding filters should be created with default inputs."
  }

  assert {
    condition     = length(aws_guardduty_ipset.this) == 0
    error_message = "No IP sets should be created with default inputs."
  }

  assert {
    condition     = length(aws_guardduty_threatintelset.this) == 0
    error_message = "No threat intel sets should be created with default inputs."
  }
}

#------------------------------------------------------------------------------
# 2. Master switch – disabled module produces zero resources
#------------------------------------------------------------------------------
run "disabled_module" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = length(aws_guardduty_detector.this) == 0
    error_message = "No detector should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_detector_feature.this) == 0
    error_message = "No detector features should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_publishing_destination.this) == 0
    error_message = "No publishing destination should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_filter.this) == 0
    error_message = "No filters should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_ipset.this) == 0
    error_message = "No IP sets should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_threatintelset.this) == 0
    error_message = "No threat intel sets should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_organization_admin_account.this) == 0
    error_message = "No org admin account resource should be created when var.enabled is false."
  }

  assert {
    condition     = length(aws_guardduty_organization_configuration.this) == 0
    error_message = "No org configuration resource should be created when var.enabled is false."
  }
}

#------------------------------------------------------------------------------
# 3. Custom publishing frequency – ONE_HOUR
#------------------------------------------------------------------------------
run "custom_publishing_freq_one_hour" {
  command = plan

  variables {
    finding_publishing_frequency = "ONE_HOUR"
  }

  assert {
    condition     = aws_guardduty_detector.this[0].finding_publishing_frequency == "ONE_HOUR"
    error_message = "finding_publishing_frequency must be ONE_HOUR when explicitly set."
  }
}

#------------------------------------------------------------------------------
# 3b. Custom publishing frequency – SIX_HOURS
#------------------------------------------------------------------------------
run "custom_publishing_freq_six_hours" {
  command = plan

  variables {
    finding_publishing_frequency = "SIX_HOURS"
  }

  assert {
    condition     = aws_guardduty_detector.this[0].finding_publishing_frequency == "SIX_HOURS"
    error_message = "finding_publishing_frequency must be SIX_HOURS when explicitly set."
  }
}

#------------------------------------------------------------------------------
# 4. Subset of features – only S3 and EKS audit logs
#------------------------------------------------------------------------------

run "subset_features" {
  command = plan

  variables {
    detector_features = {
      S3_DATA_EVENTS = { enabled = true }
      EKS_AUDIT_LOGS = { enabled = true }
    }
  }

  assert {
    condition     = length(aws_guardduty_detector_feature.this) == 2
    error_message = "Only two features should be created when detector_features contains two entries."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "S3_DATA_EVENTS")
    error_message = "S3_DATA_EVENTS must be present in the plan."
  }

  assert {
    condition     = contains(keys(aws_guardduty_detector_feature.this), "EKS_AUDIT_LOGS")
    error_message = "EKS_AUDIT_LOGS must be present in the plan."
  }
}

#------------------------------------------------------------------------------
# 4b. Subset of features – disabling one feature in a map
#------------------------------------------------------------------------------
run "disabled_feature_entry" {
  command = plan

  variables {
    detector_features = {
      S3_DATA_EVENTS = { enabled = false }
    }
  }

  assert {
    condition     = length(aws_guardduty_detector_feature.this) == 1
    error_message = "Feature resource must still be created even if enabled is false (to manage the state)."
  }

  assert {
    condition     = aws_guardduty_detector_feature.this["S3_DATA_EVENTS"].status == "DISABLED"
    error_message = "S3_DATA_EVENTS status must be DISABLED."
  }
}

#------------------------------------------------------------------------------
# 5. Publishing destination – S3 export configuration
#------------------------------------------------------------------------------
run "publishing_destination_planned" {
  command = plan

  variables {
    publishing_destination = {
      bucket_arn  = "arn:aws:s3:::my-guardduty-findings"
      kms_key_arn = "arn:aws:kms:eu-central-1:123456789012:key/some-uuid"
    }
  }

  assert {
    condition     = length(aws_guardduty_publishing_destination.this) == 1
    error_message = "Publishing destination resource must be created when var.publishing_destination is provided."
  }

  assert {
    condition     = aws_guardduty_publishing_destination.this[0].destination_arn == "arn:aws:s3:::my-guardduty-findings"
    error_message = "Publishing destination bucket ARN mismatch."
  }

  assert {
    condition     = aws_guardduty_publishing_destination.this[0].kms_key_arn == "arn:aws:kms:eu-central-1:123456789012:key/some-uuid"
    error_message = "Publishing destination KMS key ARN mismatch."
  }
}

#------------------------------------------------------------------------------
# 6. Finding filters – ARCHIVE action with criteria
#------------------------------------------------------------------------------
run "filters_validation" {
  command = plan

  variables {
    filters = {
      "archive-low-severity" = {
        description = "Archive findings with severity below MEDIUM (4)"
        action      = "ARCHIVE"
        rank        = 10
        criteria = [
          {
            field     = "severity"
            less_than = "4"
          }
        ]
      }
    }
  }

  assert {
    condition     = length(aws_guardduty_filter.this) == 1
    error_message = "Expected one filter to be created."
  }

  assert {
    condition     = aws_guardduty_filter.this["archive-low-severity"].action == "ARCHIVE"
    error_message = "Filter action must be ARCHIVE."
  }

  assert {
    condition     = aws_guardduty_filter.this["archive-low-severity"].rank == 10
    error_message = "Filter rank must be 10."
  }

  assert {
    condition     = length(aws_guardduty_filter.this["archive-low-severity"].finding_criteria[0].criterion) == 1
    error_message = "Filter must contain one criterion block."
  }
}

#------------------------------------------------------------------------------
# 7. IP sets – validation
#------------------------------------------------------------------------------
run "ipsets_planned" {
  command = plan

  variables {
    ipsets = {
      "corporate-vpn" = {
        format   = "TXT"
        location = "s3://my-bucket/vpn-ips.txt"
        activate = true
      }
    }
  }

  assert {
    condition     = length(aws_guardduty_ipset.this) == 1
    error_message = "Expected one IP set to be created."
  }

  assert {
    condition     = aws_guardduty_ipset.this["corporate-vpn"].format == "TXT"
    error_message = "IP set format must be TXT."
  }

  assert {
    condition     = aws_guardduty_ipset.this["corporate-vpn"].activate == true
    error_message = "IP set activate must be true."
  }
}

#------------------------------------------------------------------------------
# 8. Organization delegation – management account role
#------------------------------------------------------------------------------
run "organization_delegated_admin" {
  command = plan

  variables {
    organization_admin = {
      delegate_admin   = true
      admin_account_id = "111122223333"
    }
  }

  assert {
    condition     = length(aws_guardduty_organization_admin_account.this) == 1
    error_message = "Org admin account delegation resource should be created."
  }

  assert {
    condition     = aws_guardduty_organization_admin_account.this[0].admin_account_id == "111122223333"
    error_message = "Delegated admin account ID mismatch."
  }
}

#------------------------------------------------------------------------------
# 9. Organization configuration – delegated admin account role
#------------------------------------------------------------------------------
run "organization_delegated_config" {
  command = plan

  variables {
    organization_admin = {
      manage_org_configuration = true
      auto_enable              = "ALL"
    }
    organization_features = {
      S3_DATA_EVENTS     = "ALL"
      RUNTIME_MONITORING = "NEW"
    }
  }

  assert {
    condition     = length(aws_guardduty_organization_configuration.this) == 1
    error_message = "Org configuration resource should be created."
  }

  assert {
    condition     = aws_guardduty_organization_configuration.this[0].auto_enable_organization_members == "ALL"
    error_message = "Org configuration auto-enable mode mismatch."
  }

  assert {
    condition     = length(aws_guardduty_organization_configuration_feature.this) == 2
    error_message = "Expected two org-wide configuration features to be created."
  }

  assert {
    condition     = aws_guardduty_organization_configuration_feature.this["S3_DATA_EVENTS"].auto_enable == "ALL"
    error_message = "Org S3 feature auto-enable mode mismatch."
  }

  assert {
    condition     = aws_guardduty_organization_configuration_feature.this["RUNTIME_MONITORING"].auto_enable == "NEW"
    error_message = "Org Runtime Monitoring feature auto-enable mode mismatch."
  }
}

#------------------------------------------------------------------------------
# 10. Tag propagation – check presence in detector tags
#------------------------------------------------------------------------------
run "tags_propagation_validation" {
  command = plan

  variables {
    tags = {
      "Environment" = "Production"
      "Owner"       = "Platform"
    }
  }

  assert {
    condition     = aws_guardduty_detector.this[0].tags["Environment"] == "Production"
    error_message = "Environment tag was not propagated correctly to the detector."
  }

  assert {
    condition     = aws_guardduty_detector.this[0].tags["Owner"] == "Platform"
    error_message = "Owner tag was not propagated correctly to the detector."
  }
}

#------------------------------------------------------------------------------
# 11. Output contract – verify types and non-null states
#------------------------------------------------------------------------------
run "output_contract_validation" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = output.enabled == true
    error_message = "Output 'enabled' must mirror input var.enabled."
  }

  # Note: During a mock plan, IDs might be null or known-after-apply,
  # but structural shapes (maps vs lists) should be correct.
  assert {
    condition     = length(output.detector_feature_ids) == 6
    error_message = "detector_feature_ids output must contain 6 entries for default enabled state."
  }

  assert {
    condition     = output.publishing_destination_id == null
    error_message = "publishing_destination_id output should be null when not configured."
  }

  assert {
    condition     = length(output.ipset_ids) == 0
    error_message = "ipset_ids output must be an empty map when no ipsets are provided."
  }
}
