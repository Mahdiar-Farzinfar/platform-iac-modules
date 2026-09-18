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
# AWS GuardDuty Module
#
# Description:
#   Provides a comprehensive Amazon GuardDuty implementation, supporting
#   standalone accounts and AWS Organizations. This module manages the detector
#   lifecycle, advanced threat protection features (S3, EKS, Malware, etc.),
#   finding filters, and centralized publishing.
#
# Architectural Notes:
#   - Feature Management: Uses `aws_guardduty_detector_feature` to prevent
#     configuration drift inherent in the deprecated `datasources` block.
#   - Scalability: Driven by map-based variables to allow enabling/disabling
#     specific protection planes without altering the core logic.
#   - Security: Supports KMS-encrypted findings export to S3 for long-term
#     retention and compliance.
#
# Usage:
#   terraform init
#   terraform apply
#
# Dependencies:
#   - Requires IAM permissions for GuardDuty Service-Linked Roles.
#   - S3 bucket and KMS key policies must grant access to 'guardduty.amazonaws.com'
#     before enabling the publishing destination.
###############################################################################

#------------------------------------------------------------------------------
# GuardDuty Detector
#
# The primary resource representing the GuardDuty service within a specific
# Region. Only one detector can exist per account/region. We use the 'this'
# naming convention for the primary resource.
#------------------------------------------------------------------------------
resource "aws_guardduty_detector" "this" {
  count = var.enabled ? 1 : 0

  # checkov:skip=CKV2_AWS_3:GuardDuty enablement is caller-controlled for org/region-specific deployments.
  enable                       = var.enabled # conditional based on org/region (multi-account mode)
  finding_publishing_frequency = var.finding_publishing_frequency

  tags = local.tags
}

#------------------------------------------------------------------------------
# Detector Features (Protection Planes)
#
# Dynamically manages GuardDuty features such as S3_DATA_EVENTS, EKS_AUDIT_LOGS,
# and RUNTIME_MONITORING. The use of 'additional_configuration' allows for
# granular control (e.g., EKS Runtime Monitoring addons).
#------------------------------------------------------------------------------
resource "aws_guardduty_detector_feature" "this" {
  for_each = var.enabled ? var.detector_features : {}

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  status      = each.value.enabled ? "ENABLED" : "DISABLED"

  dynamic "additional_configuration" {
    for_each = each.value.additional_configuration

    content {
      name   = additional_configuration.key
      status = additional_configuration.value ? "ENABLED" : "DISABLED"
    }
  }
}

#------------------------------------------------------------------------------
# Findings Export (S3 Publishing Destination)
#
# Facilitates the export of findings to a centralized S3 bucket.
# Note: The destination bucket and KMS key must exist and have appropriate
# cross-service permissions before this resource is provisioned.
#------------------------------------------------------------------------------
resource "aws_guardduty_publishing_destination" "this" {
  count = var.enabled && var.publishing_destination != null ? 1 : 0

  detector_id      = aws_guardduty_detector.this[0].id
  destination_type = "S3"
  destination_arn  = var.publishing_destination.bucket_arn
  kms_key_arn      = var.publishing_destination.kms_key_arn
}

#------------------------------------------------------------------------------
# Trusted IP Sets
#
# CIDRs defined here are "allow-listed" and will not generate findings.
# Useful for vulnerability scanners, NAT gateways, or corporate VPNs to
# reduce false positives.
#------------------------------------------------------------------------------
resource "aws_guardduty_ipset" "this" {
  for_each = var.enabled ? var.ipsets : {}

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  format      = each.value.format
  location    = each.value.location
  activate    = each.value.activate

  tags = local.tags
}

#------------------------------------------------------------------------------
# Threat Intel Sets
#
# External threat feeds containing known malicious IP addresses.
# GuardDuty generates findings based on traffic to/from these addresses.
#------------------------------------------------------------------------------
resource "aws_guardduty_threatintelset" "this" {
  for_each = var.enabled ? var.threat_intel_sets : {}

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  format      = each.value.format
  location    = each.value.location
  activate    = each.value.activate

  tags = local.tags
}

#------------------------------------------------------------------------------
# Finding Filters
#
# Logic to automatically archive or suppress findings based on specific
# criteria. 'Rank' (1-100) dictates the order of evaluation; lower numbers
# take precedence.
#------------------------------------------------------------------------------
resource "aws_guardduty_filter" "this" {
  for_each = var.enabled ? var.filters : {}

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  description = each.value.description
  action      = each.value.action # NOOP or ARCHIVE
  rank        = each.value.rank

  finding_criteria {
    dynamic "criterion" {
      for_each = each.value.criteria

      content {
        field                 = criterion.value.field
        equals                = criterion.value.equals
        not_equals            = criterion.value.not_equals
        greater_than          = criterion.value.greater_than
        greater_than_or_equal = criterion.value.greater_than_or_equal
        less_than             = criterion.value.less_than
        less_than_or_equal    = criterion.value.less_than_or_equal
      }
    }
  }

  tags = local.tags
}

#------------------------------------------------------------------------------
# Organization Integration
#
# Implements multi-account management.
# 1. 'admin_account' designates a delegated administrator.
# 2. 'configuration' sets the auto-enable behavior for the entire Org.
# 3. 'feature' sets auto-enable for specific protection planes (e.g. S3)
#    across the Org.
#------------------------------------------------------------------------------
resource "aws_guardduty_organization_admin_account" "this" {
  count = var.enabled && var.organization_admin.delegate_admin ? 1 : 0

  admin_account_id = var.organization_admin.admin_account_id
}

resource "aws_guardduty_organization_configuration" "this" {
  count = var.enabled && var.organization_admin.manage_org_configuration ? 1 : 0

  detector_id                      = aws_guardduty_detector.this[0].id
  auto_enable_organization_members = var.organization_admin.auto_enable # ALL | NEW | NONE

  depends_on = [aws_guardduty_organization_admin_account.this]
}

resource "aws_guardduty_organization_configuration_feature" "this" {
  for_each = var.enabled && var.organization_admin.manage_org_configuration ? var.organization_features : {}

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  auto_enable = each.value # ALL | NEW | NONE

  depends_on = [aws_guardduty_organization_configuration.this]
}
