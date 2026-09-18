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
# AWS GuardDuty Module - Outputs
#
# Description:
#   Exposes the identifiers and metadata of every resource managed by this
#   module. Callers use these values to:
#     - Wire downstream resources (e.g. EventBridge rules, IAM conditions).
#     - Express explicit `depends_on` edges in the root module when implicit
#       references are insufficient (e.g. member-account enrollment must wait
#       for feature configuration to complete).
#     - Satisfy audit / compliance queries without requiring direct data-source
#       lookups.
#
# Design Notes:
#   - All outputs referencing count-gated resources (gated on var.enabled or
#     a compound condition) use try() to return null rather than raising an
#     index error during a plan where the resource was not created. Callers
#     should guard downstream usage with `can()` or a conditional expression
#     when null is a meaningful branch.
#   - For_each-backed resources expose their full map so that callers can
#     iterate or select individual entries by key without requiring an
#     additional data source.
#   - The `tags` output re-exports the resolved tag set (module defaults merged
#     with var.tags) to allow root-level auditing without re-deriving the merge.
###############################################################################

#------------------------------------------------------------------------------
# Module State
#------------------------------------------------------------------------------
output "enabled" {
  description = "Whether the GuardDuty module is enabled. Mirrors var.enabled and is useful as a guard expression in conditional resources in the root module."
  value       = var.enabled
}

#------------------------------------------------------------------------------
# Detector
#------------------------------------------------------------------------------
output "detector_id" {
  description = "The unique identifier of the GuardDuty detector in this Region. Null when var.enabled is false. Required by member-account enrollment and EventBridge event-pattern rules."
  value       = local.detector_id
}

output "detector_arn" {
  description = "The ARN of the GuardDuty detector. Null when var.enabled is false. Use in IAM resource conditions and cross-service resource policies."
  value       = try(aws_guardduty_detector.this[0].arn, null)
}

output "account_id" {
  description = "The AWS account ID in which the detector was created. Null when var.enabled is false."
  value       = try(aws_guardduty_detector.this[0].account_id, null)
}

#------------------------------------------------------------------------------
# Detector Features (Protection Planes)
#------------------------------------------------------------------------------
output "detector_feature_ids" {
  description = <<-EOT
    Map of feature name (e.g. "S3_DATA_EVENTS", "EKS_AUDIT_LOGS") to the
    internal resource ID of each aws_guardduty_detector_feature. Empty map
    when var.enabled is false or var.detector_features is empty.

    Primary use: `depends_on` reference in the root module to ensure all
    protection planes are fully configured before enrolling member accounts
    or attaching policies that react to specific finding types.
  EOT
  value       = { for k, v in aws_guardduty_detector_feature.this : k => v.id }
}

#------------------------------------------------------------------------------
# Publishing Destination
#------------------------------------------------------------------------------
output "publishing_destination_id" {
  description = "The ID of the S3 publishing destination. Null when no publishing_destination is configured or var.enabled is false."
  value       = try(aws_guardduty_publishing_destination.this[0].id, null)
}

#------------------------------------------------------------------------------
# IP Sets
#------------------------------------------------------------------------------
output "ipset_ids" {
  description = <<-EOT
    Map of IP-set name to its resource ID. Empty map when var.enabled is
    false or var.ipsets is empty. Use the individual IDs in IAM or CloudWatch
    rules that reference specific allow-listed feeds.
  EOT
  value       = { for k, v in aws_guardduty_ipset.this : k => v.id }
}

#------------------------------------------------------------------------------
# Threat Intelligence Sets
#------------------------------------------------------------------------------
output "threat_intel_set_ids" {
  description = <<-EOT
    Map of threat-intel-set name to its resource ID. Empty map when
    var.enabled is false or var.threat_intel_sets is empty.
  EOT
  value       = { for k, v in aws_guardduty_threatintelset.this : k => v.id }
}

#------------------------------------------------------------------------------
# Finding Filters
#------------------------------------------------------------------------------
output "filter_ids" {
  description = <<-EOT
    Map of filter name to its resource ID (format: "<detector_id>:<filter_name>").
    Empty map when var.enabled is false or var.filters is empty.
  EOT
  value       = { for k, v in aws_guardduty_filter.this : k => v.id }
}

#------------------------------------------------------------------------------
# Organizations Integration
#------------------------------------------------------------------------------
output "organization_admin_account_id" {
  description = <<-EOT
    The AWS account ID that was registered as the GuardDuty delegated
    administrator. Mirrors var.organization_admin.admin_account_id when
    delegation was performed; null otherwise.

    NOTE: This value is always the admin account ID, not the current account.
    The resource itself has no meaningful attributes beyond the ID it was
    passed, so this output simply confirms successful delegation.
  EOT
  value       = try(aws_guardduty_organization_admin_account.this[0].id, null)
}

output "organization_configuration_id" {
  description = <<-EOT
    The detector ID acting as the key for the Organization configuration
    resource. Null when manage_org_configuration is false or var.enabled is
    false. Useful as a `depends_on` target for resources that must be created
    after the org-wide auto-enable policy is in place.
  EOT
  value       = try(aws_guardduty_organization_configuration.this[0].id, null)
}

output "organization_feature_ids" {
  description = <<-EOT
    Map of organization feature name (e.g. "S3_DATA_EVENTS") to the internal
    resource ID of each aws_guardduty_organization_configuration_feature.
    Empty map when manage_org_configuration is false, var.enabled is false,
    or var.organization_features is empty.
  EOT
  value       = { for k, v in aws_guardduty_organization_configuration_feature.this : k => v.id }
}

#------------------------------------------------------------------------------
# Tag Metadata
#------------------------------------------------------------------------------
output "tags" {
  description = "The effective tag set applied to all taggable resources (module default tags merged with var.tags). Useful for root-module audit outputs and downstream tag-based IAM conditions."
  value       = local.tags
}
