# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------

TASK ?= task

MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
MAKEFLAGS += --warn-undefined-variables

.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------

.PHONY: help
help:
	@$(TASK) --list

# ------------------------------------------------------------------------------
# ALIASES
# ------------------------------------------------------------------------------

TASK_ALIAS := \
  default=default \
  preflight=preflight \
  bootstrap=bootstrap \
  bootstrap-posix=bootstrap:posix \
  bootstrap-windows=bootstrap:windows \
  init=init \
  os-detect=os:detect \
  ci-changed=ci:changed \
  test-cross-platform=test:cross-platform \
  test-cross-platform-linux=test:cross-platform:linux \
  test-cross-platform-macos=test:cross-platform:macos \
  test-cross-platform-windows=test:cross-platform:windows \
  fmt=fmt \
  fmt-terraform=fmt:terraform \
  fmt-go=fmt:go \
  fmt-shell=fmt:shell \
  fmt-shell-windows=fmt:shell:windows \
  validate-terraform=validate:terraform \
  lint=lint \
  lint-tflint=lint:tflint \
  lint-yaml=lint:yaml \
  lint-md=lint:md \
  lint-actions=lint:actions \
  validate-go=validate:go \
  lint-go=lint:go \
  security=security \
  security-gitleaks=security:gitleaks \
  security-all=security:all \
  docs=docs \
  docs-check=docs:check \
  test-terraform=test:terraform \
  test-go=test:go \
  test=test \
  test-smoke=test:smoke \
  quick=quick \
  ci=ci \
  ci-non-security=ci:non-security \
  full=full \
  release-check=release-check \
  verify-toolchain=verify:toolchain \
  verify-outputs=verify:outputs

define TASK_ALIAS_RULE
.PHONY: $(1)
$(1):
	@$(TASK) $(2)
endef

$(foreach pair,$(TASK_ALIAS), \
  $(eval $(call TASK_ALIAS_RULE, \
    $(word 1,$(subst =, ,$(pair))), \
    $(word 2,$(subst =, ,$(pair))))))
