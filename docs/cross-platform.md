# Cross-platform development

`platform-iac-modules` is a catalog of reusable Terraform modules. The
repository is developed and validated on Linux, macOS, Windows, and in the
Dev Container. The supported workflows are deliberately centered on the same
Taskfile, version pins, and validation scripts so that a change behaves the
same way locally and in GitHub Actions.

This repository is not a live Terraform root. Develop and test the modules
here, then consume released modules from a separate infrastructure repository.
Do not run `terraform apply` from the repository root.

## Supported environments

| Environment | Primary entry point | CI coverage |
| --- | --- | --- |
| Linux | Bash plus `task` | `cross-platform-test.yml` on `ubuntu-24.04` |
| macOS | Bash plus `task` | `cross-platform-test.yml` on `macos-14` (arm64) |
| Windows | PowerShell plus `task` | `cross-platform-test.yml` on `windows-latest` |
| Dev Container | VS Code and Docker | Image build and validation workflows |

Use a native environment when you need to reproduce an operating-system
specific issue. Use the Dev Container when you want a controlled Linux
toolchain without installing the dependencies on the host.

## Repository source of truth

The following files define the cross-platform contract:

- `Taskfile.yml` — canonical local task orchestration and OS dispatch.
- `tooling/.tool-versions` — pinned versions for Terraform, Python, Go tools,
  linters, scanners, and supporting utilities.
- `tooling/.terraform-version` — canonical Terraform version.
- `go.mod` — canonical Go language/toolchain version.
- `tooling/cross-platform/asdf-tool-versions` — mirror checked by
  `verify-toolchain.py`.
- `.devcontainer/devcontainer.json` — Dev Container Terraform and Go mirrors.
- `.editorconfig` and `.gitattributes` — formatting and line-ending policy.

When changing a version, update the canonical source and all required mirrors,
then run the toolchain verifier before opening a pull request.

## Bootstrap

### Recommended Taskfile path

From the repository root, install the pinned command-line tools with:

```text
task bootstrap
```

This runs `scripts/tools/install-tools-posix.go` on Linux/macOS and
`scripts/tools/install-tools-windows.go` on Windows. The installer may use a
supported package manager or version manager; review its output before
accepting changes to the host.

The Taskfile also exposes platform-aware setup wrappers. They default to
`--plan`, so the first run is safe to review:

```bash
task bootstrap:posix
bash scripts/bootstrap/setup.sh --plan
```

```powershell
task bootstrap:windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap\setup.ps1 --plan
```

Apply the planned changes explicitly:

```bash
bash scripts/bootstrap/setup.sh --apply --non-interactive
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap\setup.ps1 --apply --non-interactive
```

`scripts/bootstrap/setup.py` is the bootstrap source of truth; `setup.sh` and
`setup.ps1` are thin wrappers that detect the host and pass the arguments
through. Keep those wrappers behaviorally equivalent when modifying them.

### Verify the environment

Run the commands for the shell you are using. The `--root` and `--strict`
arguments are required for repository preflight:

```bash
python3 scripts/tools/verify-toolchain.py \
  --root . \
  --tool-versions-file tooling/.tool-versions \
  --terraform-version-file tooling/.terraform-version \
  --go-mod-file go.mod
python3 scripts/tools/verify-env.py --root . --strict
```

On Windows, use `python` (or `py -3`) instead of `python3`:

```powershell
python scripts/tools/verify-toolchain.py `
  --root . `
  --tool-versions-file tooling/.tool-versions `
  --terraform-version-file tooling/.terraform-version `
  --go-mod-file go.mod
python scripts/tools/verify-env.py --root . --strict
```

The first verifier checks the canonical pins against the asdf and Dev
Container mirrors. The second checks repository shape, required commands, and
runtime availability; strict mode treats actionable warnings as failures.

For the same checks through the Taskfile, run:

```text
task preflight
```

## Task runner conventions

Run tasks from the repository root. Use `task --list` to see the complete
catalog. Tasks that have `platforms` constraints dispatch only on the native
operating system; they do not emulate another OS.

| Task | Purpose |
| --- | --- |
| `task os:detect` | Print the detected OS and architecture. |
| `task preflight` | Verify pins, required files, and the strict environment. |
| `task init` | Initialize every module with the backend disabled. |
| `task fmt` | Run Terraform, Go, and POSIX-shell formatters where applicable. |
| `task lint` | Run YAML, Markdown, Actions, Terraform, Go, and TFLint checks. |
| `task test:terraform` | Run native `*.tftest.hcl` tests. |
| `task test:go` | Run Go tests, including integration tests when configured. |
| `task test:smoke` | Run catalog-driven offline module smoke tests. |
| `task test:cross-platform` | Run the native OS cross-platform suite. |
| `task security:all` | Run Checkov, Trivy, and Gitleaks checks. |
| `task docs:check` | Regenerate/check module documentation and fail on drift. |
| `task ci:non-security` | Local equivalent of the non-security Validate gates. |
| `task ci` | Full local CI pass, including security scans. |

`task ci:non-security` mirrors the validation workflow. Security scanning is
also run by dedicated workflows, so `task ci` is the broader local check.
Tasks do not auto-fix files; run `task fmt` or `task docs` intentionally when
you want to update generated or formatted content.

## Native cross-platform test suites

The scripts under `tests/cross-platform/` exercise the same gates on each
supported OS:

- `test-linux.sh` — run with Bash on Linux.
- `test-macos.sh` — run with Bash 3.x-compatible syntax on macOS.
- `test-windows.ps1` — run with PowerShell on Windows.

Use the Taskfile entry points so the correct script and interpreter are
selected:

```bash
task test:cross-platform:linux
```

```bash
task test:cross-platform:macos
```

```powershell
task test:cross-platform:windows
```

Each suite checks the pinned Terraform and Python versions, runs the
toolchain/environment verifiers, validates every selected module with
`terraform fmt`, offline `terraform init`, `terraform validate`, and native
Terraform tests, and runs the available TFLint, Checkov, Trivy, and yamllint
gates. Pass a module filter directly to a script when diagnosing one module:

```bash
bash tests/cross-platform/test-linux.sh --modules kms
```

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/cross-platform/test-windows.ps1 -Modules kms
```

The scripts write diagnostic output under `tests/cross-platform/output/`.
Generated output is for troubleshooting and CI artifacts; do not commit it.

GitHub Actions runs the three native suites in
`.github/workflows/cross-platform-test.yml` on relevant changes, compiles and
smoke-tests the platform-specific Go installers, and uploads any diagnostics.
The workflow is also available through `workflow_dispatch` and
`workflow_call`.

## Windows-specific guidance

Use PowerShell 5.1 or PowerShell 7 (`pwsh`) and invoke repository scripts with
`-NoProfile -ExecutionPolicy Bypass` when a local execution policy blocks a
checked-in script. `scripts/windows/tasks.ps1` is the Windows implementation
behind Taskfile operations that need PowerShell; keep its task names and
arguments aligned with the POSIX branches.

Avoid assuming that GNU utilities, `/bin/sh`, or POSIX path syntax exists on
Windows. Put shared behavior in Python or Go, use Taskfile OS dispatch, and
keep shell- or PowerShell-specific code in its corresponding wrapper.

## Shell, paths, and line endings

- Use forward-slash paths in documentation and Terraform source addresses.
- Keep checked-in text files UTF-8 with LF endings, as required by
  `.editorconfig` and `.gitattributes`. Git may present PowerShell files with
  Windows line endings according to the repository attributes.
- Run scripts with their intended interpreter: Bash scripts with Bash, and
  `.ps1` scripts with PowerShell.
- Do not depend on the current working directory inside scripts; repository
  scripts resolve paths from their own location.
- Avoid writing secrets, credentials, or machine-specific absolute paths to
  generated output.

## Dev Container parity

The Dev Container is defined by `.devcontainer/devcontainer.json` and
`.devcontainer/Dockerfile`. Its Terraform and Go feature versions must match
the canonical files verified by `scripts/tools/verify-toolchain.py`.

After reopening the repository in the container, run:

```bash
task preflight
task ci:non-security
```

The container is a reproducibility aid, not a substitute for native Windows
or macOS testing. Changes to bootstrap wrappers, path handling, or
OS-specific scripts should still be exercised on the affected host or by the
corresponding CI job.

## Module development and release refs

Work inside one directory under `modules/` and run its Terraform commands with
the backend disabled for local validation. The module catalog and generated
documentation are checked by the normal Taskfile and CI gates.

Consumers should pin an immutable module release ref. Module tags use the
`module/<module-name>/v<semver>` convention; for example:

```hcl
module "cloudtrail" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/cloudtrail?ref=module/cloudtrail/v1.2.0"
}
```

Do not use a moving branch or the repository root as a module source when
reproducibility matters. See `docs/versioning.md` for the complete release
policy.

## Credentials and cloud-backed tests

Formatting, validation, native Terraform tests, smoke tests, cross-platform
tests, and static security scans should not require AWS credentials. Terratest
integration tests do create real resources and require an explicitly
configured sandbox account. Run them only with the `integration` build tag,
use the repository timeout (`30m`), and clean up resources after the test.

Never place credentials in source files, `.tfvars` committed to Git, test
output, or CI logs.

## Troubleshooting

1. Run `task os:detect` and confirm the expected host and architecture.
2. Re-run `task preflight` to identify missing commands or version drift.
3. Compare `tooling/.tool-versions`, `tooling/.terraform-version`,
   `tooling/cross-platform/asdf-tool-versions`, and
   `.devcontainer/devcontainer.json`.
4. On Windows, confirm `terraform`, `python`, `go`, and `task` resolve from
   PowerShell and that the execution policy permits the wrapper invocation.
5. On macOS, confirm Bash is available and that Homebrew-installed tools are
   on `PATH`.
6. Run the native cross-platform script with `--modules <name>` and inspect
   `tests/cross-platform/output/`.
7. Compare the failing local task with its job in
   `.github/workflows/cross-platform-test.yml`.

Common causes are an unrefreshed PATH after installing a tool, a version
manager using a different pin, CRLF-only edits to POSIX scripts, and running a
platform-specific script through the wrong shell.

## Related files

- `README.md` and `CONTRIBUTING.md`
- `Taskfile.yml`
- `scripts/bootstrap/setup.py`, `setup.sh`, and `setup.ps1`
- `scripts/windows/tasks.ps1`
- `scripts/tools/install-tools-posix.go` and `install-tools-windows.go`
- `scripts/tools/verify-toolchain.py` and `verify-env.py`
- `tests/README.md`
- `tests/cross-platform/`
- `tests/smoke/`
- `tooling/.tool-versions`
- `tooling/.terraform-version`
- `tooling/cross-platform/asdf-tool-versions`
- `.devcontainer/`
- `.vscode/`
- `.github/workflows/cross-platform-test.yml`
- `.github/workflows/validate.yml`
- `.github/workflows/devcontainer-image.yml`
