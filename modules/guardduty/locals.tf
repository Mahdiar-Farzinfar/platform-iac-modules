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
# AWS GuardDuty Module - Local Values
#
# Description:
#   Centralizes derived values and the canonical tag set consumed by the
#   resources in main.tf. Keeping computation here (rather than inline)
#   keeps resource blocks declarative and ensures a single source of truth
#   for cross-cutting concerns such as tagging.
#
# Design Notes:
#   - Module-owned tags are defined first, then overridden by caller-supplied
#     var.tags. This lets consumers intentionally override defaults (e.g.
#     ManagedBy) while still inheriting sane baselines.
#   - Only values actually referenced by main.tf are exposed to avoid dead
#     locals and configuration drift between files.
###############################################################################

locals {
  #----------------------------------------------------------------------------
  # Module Identity
  #
  # Static metadata describing the module. Surfaced as tags to make ownership
  # and provenance auditable directly from the AWS console / Config.
  #----------------------------------------------------------------------------
  module_name = "guardduty"

  #----------------------------------------------------------------------------
  # Tag Composition
  #
  # Baseline tags owned by the module, merged with (and overridable by)
  # caller-supplied var.tags. `merge` applies later arguments last, so
  # var.tags wins on key collisions by design.
  #
  # Consumed by every taggable resource in main.tf via `local.tags`.
  #----------------------------------------------------------------------------
  default_tags = {
    "ManagedBy" = "terraform"
    "Module"    = local.module_name
  }

  tags = merge(local.default_tags, var.tags)

  #----------------------------------------------------------------------------
  # Detector Reference
  #
  # The detector is gated behind `count`, so its attributes are only valid
  # when var.enabled is true. Resolving the id once here documents the
  # count-index access pattern and keeps main.tf resource blocks readable.
  #
  # NOTE: Guarded with try() so that referencing this local during a disabled
  # (var.enabled = false) plan does not raise an index error. Resources that
  # use the detector id are themselves gated on var.enabled, so a null value
  # is never actually consumed.
  #----------------------------------------------------------------------------
  detector_id = try(aws_guardduty_detector.this[0].id, null)
}
