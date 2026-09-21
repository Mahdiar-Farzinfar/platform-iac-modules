# Tests

Testing strategy, entry points, and conventions for `platform-iac-modules`.

## Test layers

| Layer | Scope | AWS credentials | Location |
| --- | --- | --- | --- |
| Smoke | `fmt` / `init -backend=false` / `validate` for every catalog module | No | `tests/smoke/` |
| Native (`terraform test`) | Unit tests with mocked providers, plan-mode assertions | No | `modules/<name>/tests/*.tftest.hcl` |
| Integration (Terratest) | Real apply/verify/destroy against AWS | **Yes** | `modules/<name>/tests/*_test.go` (build tag `integration`) |
| Cross-platform | Toolchain and script parity on Linux, macOS, Windows | No | `tests/cross-platform/` |

## Directory layout

```text
tests/
├── README.md                      # This file
├── smoke/
│   ├── run-smoke-tests.py         # Reference implementation (catalog-driven)
│   ├── run-smoke-tests.sh         # POSIX wrapper (Linux/macOS)
│   └── run-smoke-tests.ps1        # PowerShell wrapper (Windows)
└── cross-platform/
├── test-linux.sh
├── test-macos.sh
└── test-windows.ps1
```

## Prerequisites

The pinned toolchain is defined in `tooling/.tool-versions` and
`tooling/.terraform-version` (single source of truth):

| Tool | Version |
| --- | --- |
| terraform | 1.6.6 |
| terraform-docs | 0.17.0 |
| tflint | 0.50.3 |
| go | 1.22.0 |
| python | 3.12.2 |
| just | 1.25.0 |

Before running any tests, verify your environment:

```bash
# Repository shape, required files, runtime availability (Python, Git, Go, Terraform)
python3 scripts/tools/verify-env.py --root . --strict

# Pinned versions vs. mirrors (asdf-tool-versions, devcontainer.json)
python3 scripts/tools/verify-toolchain.py \
  --root "." \
  --tool-versions-file "tooling/.tool-versions" \
  --terraform-version-file "tooling/.terraform-version" \
  --go-mod-file "go.mod"
```

Both verifiers exit `0` on success and `1` on mismatch, parse error, or a
missing file. `verify-env.py --strict` also fails on warnings.

To install the pinned toolchain, use the platform installers under
`scripts/tools/` (`install-tools-posix.go` / `install-tools-windows.go`), or
`asdf` with `tooling/cross-platform/asdf-tool-versions`.

## Smoke tests

Smoke tests are **catalog-driven**: they iterate over `catalog/modules.yaml`
(`modules[].name` / `modules[].path`) rather than globbing directories, so the
catalog stays the single source of truth.

`run-smoke-tests.py` is the reference implementation; the `.sh` and `.ps1`
files are thin wrappers that resolve the Python interpreter and forward
arguments unchanged.

Per module, the smoke run executes (offline, no AWS credentials):

1. `terraform fmt -check -recursive`
2. `terraform init -backend=false -input=false`
3. `terraform validate`
4. `tflint --config tooling/.tflint.hcl` (skipped with `--skip-lint`)

Usage:

```bash
# All catalog modules
./tests/smoke/run-smoke-tests.sh

# Single module, without lint
./tests/smoke/run-smoke-tests.sh --module kms --skip-lint

# Windows
pwsh -File tests/smoke/run-smoke-tests.ps1 -Module kms

Exit codes: `0` all modules passed; `1` at least one check failed;
`2` internal error (bad catalog, missing tool).

`TF_IN_AUTOMATION=true` is set by the task runner for all Terraform
invocations.
```

## Module tests (example: `kms`)

### Native `terraform test` (no AWS credentials)

`modules/kms/tests/kms.tftest.hcl` uses a `mock_provider` for AWS (mocked
`aws_caller_identity` / `aws_partition`), runs mostly in `command = plan`
mode with one `apply` run for output shape, and validates variable
constraints via `expect_failures`:

```bash
cd modules/kms
terraform test
```

### Terratest integration (real AWS)

`modules/kms/tests/integration_test.go` is guarded by the
`//go:build integration` tag and runs a real apply/destroy cycle: key state,
rotation, key spec, policy, alias resolution, real Encrypt/Decrypt, tag
propagation, idempotency.

> **Warning:** creates billable AWS resources. The KMS key is scheduled for
> deletion with a 7-day window. Use a sandbox account.

```bash
cd modules/kms/tests
go test -tags=integration -timeout 30m ./...
```

The 30-minute timeout matches `GO_TEST_TIMEOUT` in `Taskfile.yml`.

## Cross-platform tests

`tests/cross-platform/test-{linux,macos}.sh` and `test-windows.ps1` verify on
each OS that: the pinned toolchain resolves correctly, version outputs pass
`scripts/tools/validate-outputs.py` (allowlisted patterns, injection-safe),
and the smoke wrapper for that platform runs end-to-end.

They are executed by `.github/workflows/cross-platform-test.yml` on pull
requests and pushes to `main`.

## CI integration

- `.github/workflows/validate.yml` (`Validate`) runs on PRs to `main`
  (opened / synchronize / reopened / ready_for_review) and on pushes to
  `main`, with path filters covering `modules/**`, `tooling/**`,
  `catalog/**`, `scripts/**`, the task runner files, and the workflows.
- `scripts/ci/build-matrix.py` emits the changed-module matrix consumed by
  GitHub Actions:

```json
  {"include": [{"name": "kms", "path": "modules/kms"}]}
```
