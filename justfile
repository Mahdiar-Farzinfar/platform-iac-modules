# justfile
# A thin, cross-platform wrapper for the Taskfile.yml targets.
# Usage: just <recipe>
#
# Note: This file does *not* duplicate any logic – it simply
#       delegates to `task <original-name>` so that your
#       Taskfile remains the single source of truth.
#
# Recipes map 1:1 to *public* Taskfile tasks (internal tasks are not exposed)
#
# -----------------------------------------------------------------------------
# Default
# -----------------------------------------------------------------------------
# Show available Taskfile tasks
default:
    @task --list

# -----------------------------------------------------------------------------
# Bootstrap / Preflight
# -----------------------------------------------------------------------------
# Verify environment and required tools
preflight:
    @task preflight

# Verify canonical toolchain versions and compatibility mirrors
verify-toolchain:
    @task verify:toolchain

# Validate output patterns to prevent injection (Sanitization)
verify-outputs:
    @task verify:outputs

# Bootstrap local dev environment (install tooling)
bootstrap:
    @task bootstrap

# Bootstrap on POSIX (linux / macOS)
# Example: just bootstrap-posix -- --plan
#          just bootstrap-posix -- --apply
bootstrap-posix *args:
    @task bootstrap:posix -- {{args}}

# Bootstrap on Windows
# Example: just bootstrap-windows -- --plan
bootstrap-windows *args:
    @task bootstrap:windows -- {{args}}

# Initialize Terraform across all modules
init:
    @task init

# -----------------------------------------------------------------------------
# OS / Cross-platform Detection
# -----------------------------------------------------------------------------
# Print detected OS/arch
os-detect:
    @task os:detect

# Detect changed modules/files for CI
ci-changed:
    @task ci:changed

# Cross-platform tests (aggregator)
test-cross-platform:
    @task test:cross-platform

# Linux-specific cross-platform tests
test-cross-platform-linux:
    @task test:cross-platform:linux

# macOS-specific cross-platform tests
test-cross-platform-macos:
    @task test:cross-platform:macos

# Windows-specific cross-platform tests
test-cross-platform-windows:
    @task test:cross-platform:windows

# -----------------------------------------------------------------------------
# Formatting
# -----------------------------------------------------------------------------
# Terraform formatting (recursive)
fmt-terraform:
    @task fmt:terraform

# Go formatting (cross-platform)
fmt-go:
    @task fmt:go

# Shell formatting (POSIX only)
fmt-shell:
    @task fmt:shell

# Shell formatting (Windows stub)
fmt-shell-windows:
    @task fmt:shell:windows

# Aggregate all formatters
fmt:
    @task fmt

# -----------------------------------------------------------------------------
# Validation / Lint
# -----------------------------------------------------------------------------
# Terraform validate
validate-terraform:
    @task validate:terraform

# TFLint for Terraform modules
lint-tflint:
    @task lint:tflint

# YAML
lint-yaml:
    @task lint:yaml

# Markdown
lint-md:
    @task lint:md

# GitHub Actions
lint-actions:
    @task lint:actions

# Go vet
validate-go:
    @task validate:go

# golangci-lint
lint-go:
    @task lint:go

# Aggregate all lint/validation
lint:
    @task lint

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------
# Checkov + Trivy
security:
    @task security

# Gitleaks
security-gitleaks:
    @task security:gitleaks

# Aggregate all security scans
security-all:
    @task security:all

# -----------------------------------------------------------------------------
# Documentation
# -----------------------------------------------------------------------------
# Generate Terraform docs
docs:
    @task docs

# Ensure docs are up-to-date
docs-check:
    @task docs:check

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
# Terraform tests (tftest.hcl)
test-terraform:
    @task test:terraform

# Go integration tests
test-go:
    @task test:go

# Smoke tests (POSIX & Windows)
test-smoke:
    @task test:smoke

# Aggregate all tests
test:
    @task test

# -----------------------------------------------------------------------------
# Composite Workflows
# -----------------------------------------------------------------------------
# Fast local loop: format → validate → docs
quick:
    @task quick

# CI gates without security scanners (dedicated security pipeline)
ci-non-security:
    @task ci:non-security

# CI-equivalent checks
ci:
    @task ci

# Full local pipeline: format → lint → security → tests → docs
full:
    @task full

# Release‐gate checks
release-check:
    @task release-check
