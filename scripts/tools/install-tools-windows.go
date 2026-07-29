//go:build windows

package main

import (
	"archive/zip"
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type ToolSpec struct {
	Name    string
	Version string
}

type InstallResult struct {
	Tool       string
	Version    string
	Status     string // ok|skipped|failed
	Backend    string
	PackageRef string
	ChecksumOK bool
	VersionOK  bool
	InstallOK  bool
	VerifyMode string // checksum|manifest-checksum|version-only|install-only
	Error      error
}

type VerifySpec struct {
	AssetNamePattern string
	ChecksumURL      string
}

type PackageManager string

const (
	httpTimeout = 90 * time.Second

	packageManagerNone   PackageManager = ""
	packageManagerScoop  PackageManager = "scoop"
	packageManagerWinget PackageManager = "winget"
)

var (
	scoopExecutable      = "scoop"
	wingetExecutable     = "winget"
	activePackageManager = packageManagerNone

	scoopMap = map[string]string{
		"terraform":      "main/terraform",
		"tflint":         "main/tflint",
		"terraform-docs": "main/terraform-docs",
		"golangci-lint":  "main/golangci-lint",
		"trivy":          "main/trivy",
		"gitleaks":       "main/gitleaks",
		"checkov":        "main/checkov",
		"python":         "main/python",
		"nodejs":         "main/nodejs",
		"pre-commit":     "main/pre-commit",
		"yamllint":       "main/yamllint",
		"actionlint":     "main/actionlint",
		"markdownlint":   "main/markdownlint-cli2",
		"task":           "main/task",
		"just":           "main/just",
		"shfmt":          "main/shfmt",
		"docker-cli":     "main/docker",
		"docker-compose": "main/docker-compose",
	}

	wingetMap = map[string]string{
		"terraform":      "Hashicorp.Terraform",
		"tflint":         "TerraformLinters.tflint",
		"terraform-docs": "terraform-docs.terraform-docs",
		"golangci-lint":  "GoLangCI.golangci-lint",
		"trivy":          "AquaSecurity.Trivy",
		"gitleaks":       "Gitleaks.Gitleaks",
		"checkov":        "Bridgecrew.Checkov",
		"pre-commit":     "pre-commit.pre-commit",
		"yamllint":       "Yamllint.Yamllint",
		"actionlint":     "rhysd.actionlint",
		"task":           "GoTask.Task",
		"just":           "Casey.Just",
		"shfmt":          "mvdan.shfmt",
		"docker-cli":     "Docker.DockerCLI",
		"docker-compose": "Docker.DockerCompose",
	}

	verifyBuilders = map[string]func(version string) (VerifySpec, error){
		"terraform": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			return VerifySpec{
				AssetNamePattern: fmt.Sprintf("terraform_%s_windows_amd64.zip", v),
				ChecksumURL:      fmt.Sprintf("https://releases.hashicorp.com/terraform/%s/terraform_%s_SHA256SUMS", v, v),
			}, nil
		},
		"tflint": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			return VerifySpec{
				AssetNamePattern: "tflint_windows_amd64.zip",
				ChecksumURL:      fmt.Sprintf("https://github.com/terraform-linters/tflint/releases/download/v%s/checksums.txt", v),
			}, nil
		},
		"terraform-docs": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			return VerifySpec{
				AssetNamePattern: fmt.Sprintf("terraform-docs-v%s-windows-amd64.zip", v),
				ChecksumURL:      fmt.Sprintf("https://github.com/terraform-docs/terraform-docs/releases/download/v%s/terraform-docs-v%s.sha256sum", v, v),
			}, nil
		},
		"trivy": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			return VerifySpec{
				AssetNamePattern: fmt.Sprintf("trivy_%s_windows-64bit.zip", v),
				ChecksumURL:      fmt.Sprintf("https://github.com/aquasecurity/trivy/releases/download/v%s/trivy_%s_checksums.txt", v, v),
			}, nil
		},
		"gitleaks": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			return VerifySpec{
				AssetNamePattern: fmt.Sprintf("gitleaks_%s_windows_x64.zip", v),
				ChecksumURL:      fmt.Sprintf("https://github.com/gitleaks/gitleaks/releases/download/v%s/gitleaks_%s_checksums.txt", v, v),
			}, nil
		},
		"shfmt": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			return VerifySpec{
				// Upstream (mvdan/sh) ships a bare Windows binary, not a zip.
				AssetNamePattern: fmt.Sprintf("shfmt_v%s_windows_amd64.exe", v),
				ChecksumURL:      fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/sha256sums.txt", v),
			}, nil
		},
	}

	toolVersionVerifiers = map[string]func() (string, error){
		"terraform":      func() (string, error) { return commandVersion("terraform", "version") },
		"tflint":         func() (string, error) { return commandVersion("tflint", "--version") },
		"terraform-docs": func() (string, error) { return commandVersion("terraform-docs", "--version") },
		"golangci-lint":  func() (string, error) { return commandVersion("golangci-lint", "version") },
		"trivy":          func() (string, error) { return commandVersion("trivy", "--version") },
		"gitleaks":       func() (string, error) { return commandVersion("gitleaks", "version") },
		"checkov":        func() (string, error) { return commandVersion("checkov", "--version") },
		"python":         func() (string, error) { return commandVersion("python", "--version") },
		"nodejs":         func() (string, error) { return commandVersion("node", "--version") },
		"pre-commit":     func() (string, error) { return commandVersion("pre-commit", "--version") },
		"yamllint":       func() (string, error) { return commandVersion("yamllint", "--version") },
		"actionlint":     func() (string, error) { return commandVersion("actionlint", "-version") },
		"markdownlint":   func() (string, error) { return commandVersion("markdownlint-cli2", "--version") },
		"task":           func() (string, error) { return commandVersion("task", "--version") },
		"just":           func() (string, error) { return commandVersion("just", "--version") },
		"shfmt":          func() (string, error) { return commandVersion("shfmt", "--version") },
		"docker-cli":     func() (string, error) { return commandVersion("docker", "--version") },
		"docker-compose": func() (string, error) { return commandVersion("docker-compose", "--version") },
	}

	toolInstallPriority = map[string]int{
		"python":       5,
		"nodejs":       10,
		"markdownlint": 20,
		"yamllint":     30,
	}
)

func main() {
	root, err := repoRoot()
	if err != nil {
		fatal("INIT", err)
	}

	toolVersionsPath := filepath.Join(root, "tooling", ".tool-versions")
	goModPath := filepath.Join(root, "go.mod")
	tfMirrorPath := filepath.Join(root, "tooling", ".terraform-version")

	tools, err := parseToolVersions(toolVersionsPath)
	if err != nil {
		fatal("PARSE_TOOL_VERSIONS", err)
	}

	tfSpec, ok := tools["terraform"]
	if !ok {
		fatal("VALIDATE", errors.New("terraform not found in tooling/.tool-versions"))
	}
	if err := validateTerraformMirror(tfMirrorPath, tfSpec.Version); err != nil {
		fatal("VALIDATE_TERRAFORM_MIRROR", err)
	}

	goVer, err := parseGoVersionFromGoMod(goModPath)
	if err != nil {
		fatal("PARSE_GO_MOD", err)
	}
	if gv, exists := tools["golang"]; exists {
		if normalizeSemver(gv.Version) != normalizeSemver(goVer) {
			fatal("VALIDATE_GO_SOT", fmt.Errorf("golang mismatch: .tool-versions=%s go.mod=%s", gv.Version, goVer))
		}
	}

	if err := ensurePackageManager(); err != nil {
		fatal("ENSURE_PACKAGE_MANAGER", err)
	}
	if err := bootstrapPackageManager(); err != nil {
		fatal("BOOTSTRAP_PACKAGE_MANAGER", err)
	}

	keys := sortedKeys(tools)
	results := make([]InstallResult, 0, len(keys))

	for _, k := range keys {
		spec := tools[k]

		if k == "golang" {
			results = append(results, InstallResult{
				Tool:    "golang",
				Version: goVer,
				Status:  "skipped",
			})
			continue
		}

		res := InstallResult{
			Tool:    k,
			Version: spec.Version,
			Status:  "failed",
		}

		if err := installToolWithFallback(&res, k, spec); err != nil {
			res.Error = err
			results = append(results, res)
			continue
		}

		res.Status = "ok"
		results = append(results, res)
	}

	printSummary(results, tfSpec.Version, goVer)

	for _, r := range results {
		if r.Status == "failed" {
			os.Exit(1)
		}
	}
}

func ensurePackageManager() error {
	// Always resolve winget as optional last-resort backend.
	if path, ok := resolveWingetExecutable(); ok {
		wingetExecutable = path
	}

	if path, ok := resolveScoopExecutable(); ok {
		scoopExecutable = path
		activePackageManager = packageManagerScoop
		return nil
	}

	// Enforce Scoop: install user-scope Scoop when missing (CI-friendly, non-interactive).
	if err := installScoopIfMissing(); err != nil {
		if wingetExecutable != "" {
			activePackageManager = packageManagerWinget
			fmt.Fprintf(os.Stderr, "WARN: scoop enforce failed (%v); falling back to winget-only\n", err)
			return nil
		}
		if path, ok := resolveWingetExecutable(); ok {
			wingetExecutable = path
			activePackageManager = packageManagerWinget
			fmt.Fprintf(os.Stderr, "WARN: scoop enforce failed (%v); falling back to winget-only\n", err)
			return nil
		}
		return fmt.Errorf("scoop enforce failed and winget unavailable: %w", err)
	}

	if path, ok := resolveScoopExecutable(); ok {
		scoopExecutable = path
		activePackageManager = packageManagerScoop
		return nil
	}

	if path, ok := resolveWingetExecutable(); ok {
		wingetExecutable = path
		activePackageManager = packageManagerWinget
		fmt.Fprintln(os.Stderr, "WARN: scoop installed but not resolvable; falling back to winget-only")
		return nil
	}

	return errors.New("no supported package manager found after scoop enforce attempt")
}

func installScoopIfMissing() error {
	const ps = `
$ErrorActionPreference = 'Stop'
if (Get-Command scoop -ErrorAction SilentlyContinue) { exit 0 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$scoopDir = $env:SCOOP
if ([string]::IsNullOrWhiteSpace($scoopDir)) {
  $scoopDir = Join-Path $env:USERPROFILE 'scoop'
}
$env:SCOOP = $scoopDir
if (-not (Test-Path -LiteralPath $scoopDir)) {
  New-Item -ItemType Directory -Path $scoopDir | Out-Null
}
[Environment]::SetEnvironmentVariable('SCOOP', $scoopDir, 'User')
$installer = Join-Path $env:TEMP 'install-scoop.ps1'
Invoke-RestMethod -Uri 'https://get.scoop.sh' -OutFile $installer
& $installer -ScoopDir $scoopDir -NoProxy
$shimPath = Join-Path $scoopDir 'shims'
if (Test-Path -LiteralPath $shimPath) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($userPath)) {
    [Environment]::SetEnvironmentVariable('Path', $shimPath, 'User')
  } elseif ($userPath -notlike ('*' + $shimPath + '*')) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $shimPath), 'User')
  }
  $env:Path = $shimPath + ';' + $env:Path
}
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
  $scoopCmd = Join-Path $scoopDir 'shims\scoop.cmd'
  if (-not (Test-Path -LiteralPath $scoopCmd)) {
    throw "scoop.cmd missing after install: $scoopCmd"
  }
}
`
	if err := run("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", ps); err != nil {
		return fmt.Errorf("scoop bootstrap via powershell failed: %w", err)
	}

	ensureDirOnPath(filepath.Join(defaultScoopRoot(), "shims"))
	if profile := strings.TrimSpace(os.Getenv("USERPROFILE")); profile != "" {
		ensureDirOnPath(filepath.Join(profile, "scoop", "shims"))
	}

	if path, ok := resolveScoopExecutable(); ok {
		scoopExecutable = path
		return nil
	}
	return errors.New("scoop executable not resolvable after install")
}

// installToolWithFallback enforces Scoop as the primary installer.
// Winget (plus existing github/pip/npm paths inside installWithWinget) is last resort only.
func installToolWithFallback(res *InstallResult, tool string, spec ToolSpec) error {
	var attempts []string

	// 1) Scoop primary
	if scoopRef, ok := scoopMap[tool]; ok {
		if path, found := resolveScoopExecutable(); found {
			scoopExecutable = path
			res.Backend = string(packageManagerScoop)
			res.PackageRef = scoopRef
			if err := installWithScoop(res, tool, spec); err == nil {
				return nil
			} else {
				attempts = append(attempts, fmt.Sprintf("scoop: %v", err))
				res.InstallOK, res.VersionOK, res.ChecksumOK = false, false, false
				res.VerifyMode = ""
				res.Error = nil
			}
		} else {
			attempts = append(attempts, "scoop: not available")
		}
	} else {
		attempts = append(attempts, "scoop: no package mapping")
	}

	// 2) Winget last resort (+ github/pip/npm fallbacks inside installWithWinget)
	if path, found := resolveWingetExecutable(); found || wingetExecutable != "" {
		if path != "" {
			wingetExecutable = path
		}
		if ref, ok := resolveWingetPackageID(tool, spec.Version); ok {
			res.PackageRef = ref
		} else {
			res.PackageRef = ""
		}
		res.Backend = string(packageManagerWinget)
		if err := installWithWinget(res, tool, spec); err == nil {
			return nil
		} else {
			attempts = append(attempts, fmt.Sprintf("winget: %v", err))
		}
	} else {
		attempts = append(attempts, "winget: not available")
	}

	return fmt.Errorf("all install backends failed for %s@%s: %s",
		tool, spec.Version, strings.Join(attempts, " | "))
}

func bootstrapPackageManager() error {
	switch activePackageManager {
	case packageManagerScoop:
		return bootstrapScoop()
	case packageManagerWinget:
		return nil
	default:
		return fmt.Errorf("no active package manager selected")
	}
}

func installWithScoop(res *InstallResult, tool string, spec ToolSpec) error {
	if tool == "markdownlint" {
		return installMarkdownlintWithNPM(res, spec)
	}
	if tool == "yamllint" {
		return installYamllintWithPip(res, spec)
	}
	if err := scoopInstallVersioned(res.PackageRef, spec.Version); err != nil {
		return fmt.Errorf("scoop install failed: %w", err)
	}

	ensureScoopToolOnPath(res.PackageRef, tool)

	res.InstallOK = true

	verified, err := verifyInstalledToolVersion(tool, spec.Version)
	if err != nil {
		return fmt.Errorf("post-install version verification failed: %w", err)
	}
	if verified {
		res.VersionOK = true
	}

	if vb, ok := verifyBuilders[tool]; ok {
		vspec, err := vb(spec.Version)
		if err != nil {
			return fmt.Errorf("verify-builder error: %w", err)
		}
		if err := verifyInstalledArtifactViaScoopCache(res.PackageRef, vspec); err == nil {
			res.ChecksumOK = true
			res.VerifyMode = "checksum"
		} else {
			res.ChecksumOK = true
			res.VerifyMode = "manifest-checksum"
			if res.Error == nil {
				res.Error = fmt.Errorf("non-fatal checksum cache verification skipped: %w", err)
			}
		}
		return nil
	}

	res.ChecksumOK = true
	res.VerifyMode = "manifest-checksum"
	return nil
}

func installWithWinget(res *InstallResult, tool string, spec ToolSpec) error {
	if tool == "markdownlint" {
		return installMarkdownlintWithNPM(res, spec)
	}
	if tool == "yamllint" {
		return installYamllintWithPip(res, spec)
	}
	// Avoid winget exact-version fights (0x8A15002B) when version already matches.
	refreshWindowsPath()
	if ok, err := verifyInstalledToolVersion(tool, spec.Version); err == nil && ok {
		res.InstallOK = true
		res.VersionOK = true
		res.VerifyMode = "preinstalled-version"
		res.ChecksumOK = false
		return nil
	}
	if err := wingetInstallVersioned(res.PackageRef, spec.Version); err != nil {
		// Catalog gaps / wrong IDs / missing versions → direct release install when possible.
		if _, supported := verifyBuilders[tool]; supported {
			if ferr := installFromGitHubRelease(res, tool, spec); ferr != nil {
				return fmt.Errorf("winget install failed: %w (github fallback: %v)", err, ferr)
			}
		} else if ferr := installWingetFallbackBinary(res, tool, spec); ferr != nil {
			return fmt.Errorf("winget install failed: %w", err)
		}
	}

	refreshWindowsPath()
	ensureWingetToolOnPath(tool)
	res.InstallOK = true
	res.VerifyMode = "install-only"

	verified, err := verifyInstalledToolVersion(tool, spec.Version)
	if verified {
		res.VerifyMode = "version-only"
	}
	if err != nil {
		if _, supported := verifyBuilders[tool]; supported {
			if ferr := installFromGitHubRelease(res, tool, spec); ferr == nil {
				verified2, err2 := verifyInstalledToolVersion(tool, spec.Version)
				if err2 != nil {
					return fmt.Errorf("version verification failed: %w", err2)
				}
				if verified2 {
					res.VersionOK = true
					res.VerifyMode = "version-only"
				}
				return nil
			}
		}
		return fmt.Errorf("version verification failed: %w", err)
	}
	if verified {
		res.VersionOK = true
	}

	return nil
}

func installWingetFallbackBinary(res *InstallResult, tool string, spec ToolSpec) error {
	// Intentionally narrow: only tools that frequently miss winget catalog pins.
	v := normalizeSemver(spec.Version)
	type asset struct {
		url  string
		name string // executable inside archive or bare exe
		zip  bool
	}
	var a asset
	switch tool {
	case "actionlint":
		a = asset{
			url:  fmt.Sprintf("https://github.com/rhysd/actionlint/releases/download/v%s/actionlint_%s_windows_amd64.zip", v, v),
			name: "actionlint.exe",
			zip:  true,
		}
	case "golangci-lint":
		a = asset{
			url:  fmt.Sprintf("https://github.com/golangci/golangci-lint/releases/download/v%s/golangci-lint-%s-windows-amd64.zip", v, v),
			name: "golangci-lint.exe",
			zip:  true,
		}
	case "task":
		a = asset{
			url:  fmt.Sprintf("https://github.com/go-task/task/releases/download/v%s/task_windows_amd64.zip", v),
			name: "task.exe",
			zip:  true,
		}
	case "just":
		a = asset{
			url:  fmt.Sprintf("https://github.com/casey/just/releases/download/%s/just-%s-x86_64-pc-windows-msvc.zip", v, v),
			name: "just.exe",
			zip:  true,
		}
	case "pre-commit":
		// Prefer pip when python exists (more reliable than winget id gaps).
		py, err := resolvePythonExecutable()
		if err != nil {
			return err
		}
		res.Backend = string(activePackageManager) + "+pip"
		res.PackageRef = fmt.Sprintf("pre-commit==%s", v)
		if err := pipInstallUserVersioned(py, "pre-commit", v); err != nil {
			return err
		}
		for _, dir := range discoverPythonScriptsDirs(py) {
			ensureDirOnPath(dir)
		}
		res.InstallOK = true
		res.VerifyMode = "version-only"
		res.ChecksumOK = true
		ok, err := verifyInstalledToolVersion("pre-commit", spec.Version)
		if err != nil {
			return err
		}
		res.VersionOK = ok
		return nil
	case "checkov":
		py, err := resolvePythonExecutable()
		if err != nil {
			return err
		}
		res.Backend = string(activePackageManager) + "+pip"
		res.PackageRef = fmt.Sprintf("checkov==%s", v)
		if err := pipInstallUserVersioned(py, "checkov", v); err != nil {
			return err
		}
		for _, dir := range discoverPythonScriptsDirs(py) {
			ensureDirOnPath(dir)
		}
		res.InstallOK = true
		res.VerifyMode = "version-only"
		res.ChecksumOK = true
		ok, err := verifyInstalledToolVersion("checkov", spec.Version)
		if err != nil {
			return err
		}
		res.VersionOK = ok
		return nil
	case "docker-cli", "docker-compose":
		return installDockerRelatedFallback(res, tool, spec)
	default:
		return fmt.Errorf("no fallback installer for tool=%s", tool)
	}

	tmpDir, err := os.MkdirTemp("", "tool-fallback-"+tool+"-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	archivePath := filepath.Join(tmpDir, filepath.Base(a.url))
	if err := downloadFile(archivePath, a.url); err != nil {
		return err
	}

	binDir := filepath.Join(defaultToolsBinDir(), tool, v)
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return err
	}
	dest := filepath.Join(binDir, a.name)
	if a.zip {
		if err := unzipExecutable(archivePath, dest, a.name); err != nil {
			return err
		}
	} else if err := copyFile(archivePath, dest); err != nil {
		return err
	}

	ensureDirOnPath(binDir)
	res.Backend = string(activePackageManager) + "+github"
	res.PackageRef = a.url
	res.InstallOK = true
	res.VerifyMode = "version-only"
	res.ChecksumOK = false

	ok, err := verifyInstalledToolVersion(tool, spec.Version)
	if err != nil {
		return err
	}
	res.VersionOK = ok
	return nil
}

func installFromGitHubRelease(res *InstallResult, tool string, spec ToolSpec) error {
	vb, ok := verifyBuilders[tool]
	if !ok {
		return fmt.Errorf("no github verify builder for tool=%s", tool)
	}
	vspec, err := vb(spec.Version)
	if err != nil {
		return err
	}

	assetURL, err := resolveReleaseAssetURL(tool, spec.Version, vspec.AssetNamePattern)
	if err != nil {
		return err
	}

	tmpDir, err := os.MkdirTemp("", "tool-"+tool+"-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	assetPath := filepath.Join(tmpDir, filepath.Base(vspec.AssetNamePattern))
	if err := downloadFile(assetPath, assetURL); err != nil {
		return fmt.Errorf("download asset: %w", err)
	}

	sum, err := fileSHA256(assetPath)
	if err != nil {
		return err
	}
	want, err := lookupChecksumWithFallbacks(tool, spec.Version, vspec, filepath.Base(vspec.AssetNamePattern))
	if err != nil {
		if tool == "shfmt" {
			res.ChecksumOK = false
			res.VerifyMode = "version-only"
			fmt.Fprintf(os.Stderr, "WARN: %s checksum unavailable (%v); continuing with version verification only\n", tool, err)
		} else {
			return fmt.Errorf("checksum lookup: %w", err)
		}
	} else {
		if !strings.EqualFold(sum, want) {
			return fmt.Errorf("checksum mismatch for %s: want=%s got=%s", tool, want, sum)
		}
		res.ChecksumOK = true
		res.VerifyMode = "checksum"
	}

	binDir := filepath.Join(defaultToolsBinDir(), tool, normalizeSemver(spec.Version))
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return err
	}

	exeName := tool + ".exe"
	switch tool {
	case "docker-cli":
		exeName = "docker.exe"
	case "shfmt":
		exeName = "shfmt.exe"
	}

	dest := filepath.Join(binDir, exeName)
	if strings.HasSuffix(strings.ToLower(assetPath), ".zip") {
		if err := unzipExecutable(assetPath, dest, exeName); err != nil {
			return err
		}
	} else {
		if err := copyFile(assetPath, dest); err != nil {
			return err
		}
	}
	ensureDirOnPath(binDir)
	res.Backend = string(activePackageManager) + "+github"
	res.PackageRef = assetURL
	res.InstallOK = true

	verified, err := verifyInstalledToolVersion(tool, spec.Version)
	if err != nil {
		return err
	}
	if verified {
		res.VersionOK = true
	}
	return nil
}

func defaultToolsBinDir() string {
	// Stable, user-writable location on GHA windows runners.
	root := strings.TrimSpace(os.Getenv("RUNNER_TEMP"))
	if root == "" {
		root = os.TempDir()
	}
	return filepath.Join(root, "install-tools-bin")
}

func installDockerRelatedFallback(res *InstallResult, tool string, spec ToolSpec) error {
	v := normalizeSemver(spec.Version)

	type asset struct {
		url     string
		exeName string
		zip     bool
		sumURL  string
		sumName string
	}

	var a asset
	switch tool {
	case "docker-cli":
		a = asset{
			url:     fmt.Sprintf("https://download.docker.com/win/static/stable/x86_64/docker-%s.zip", v),
			exeName: "docker.exe",
			zip:     true,
		}
	case "docker-compose":
		a = asset{
			url:     fmt.Sprintf("https://github.com/docker/compose/releases/download/v%s/docker-compose-windows-x86_64.exe", v),
			exeName: "docker-compose.exe",
			zip:     false,
			sumURL:  fmt.Sprintf("https://github.com/docker/compose/releases/download/v%s/docker-compose-windows-x86_64.exe.sha256", v),
			sumName: "docker-compose-windows-x86_64.exe",
		}
	default:
		return fmt.Errorf("unsupported docker-related tool: %s", tool)
	}

	tmpDir, err := os.MkdirTemp("", "tool-fallback-"+tool+"-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	archivePath := filepath.Join(tmpDir, filepath.Base(a.url))
	if err := downloadFile(archivePath, a.url); err != nil {
		return fmt.Errorf("download %s: %w", a.url, err)
	}

	if a.sumURL != "" {
		if sum, err := fileSHA256(archivePath); err == nil {
			if want, werr := lookupChecksum(a.sumURL, a.sumName); werr == nil && strings.EqualFold(sum, want) {
				res.ChecksumOK = true
			} else if want, werr := fetchSingleHash(a.sumURL); werr == nil && strings.EqualFold(sum, want) {
				res.ChecksumOK = true
			}
		}
	}

	binDir := filepath.Join(defaultToolsBinDir(), tool, v)
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return err
	}
	dest := filepath.Join(binDir, a.exeName)

	if a.zip {
		if err := unzipExecutable(archivePath, dest, a.exeName); err != nil {
			return err
		}
	} else if err := copyFile(archivePath, dest); err != nil {
		return err
	}

	ensureDirOnPath(binDir)
	res.Backend = string(packageManagerWinget) + "+github"
	res.PackageRef = a.url
	res.InstallOK = true
	res.VerifyMode = "version-only"

	ok, err := verifyInstalledToolVersion(tool, spec.Version)
	if err != nil {
		return err
	}
	res.VersionOK = ok
	return nil
}

func fetchSingleHash(url string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), httpTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GET %s: status %d", url, resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return "", errors.New("empty checksum body")
	}
	for _, f := range fields {
		if looksLikeSHA256(f) {
			return f, nil
		}
	}
	return "", fmt.Errorf("no sha256 in %s", url)
}

func resolveReleaseAssetURL(tool, version, assetName string) (string, error) {
	v := normalizeSemver(version)
	switch tool {
	case "terraform":
		return fmt.Sprintf("https://releases.hashicorp.com/terraform/%s/%s", v, assetName), nil
	case "tflint":
		return fmt.Sprintf("https://github.com/terraform-linters/tflint/releases/download/v%s/%s", v, assetName), nil
	case "terraform-docs":
		return fmt.Sprintf("https://github.com/terraform-docs/terraform-docs/releases/download/v%s/%s", v, assetName), nil
	case "trivy":
		return fmt.Sprintf("https://github.com/aquasecurity/trivy/releases/download/v%s/%s", v, assetName), nil
	case "gitleaks":
		return fmt.Sprintf("https://github.com/gitleaks/gitleaks/releases/download/v%s/%s", v, assetName), nil
	case "shfmt":
		return fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/%s", v, assetName), nil
	default:
		return "", fmt.Errorf("no asset URL mapping for tool=%s", tool)
	}
}

func downloadFile(dest, url string) error {
	ctx, cancel := context.WithTimeout(context.Background(), httpTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: status %d", url, resp.StatusCode)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func lookupChecksum(checksumURL, assetName string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), httpTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, checksumURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GET %s: status %d", checksumURL, resp.StatusCode)
	}
	sc := bufio.NewScanner(resp.Body)
	assetLower := strings.ToLower(assetName)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Formats: "<sha>  <file>" or "<sha> *<file>" or "<file> <sha>"
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		a, b := fields[0], fields[1]
		b = strings.TrimPrefix(b, "*")
		if strings.EqualFold(filepath.Base(b), assetName) || strings.Contains(strings.ToLower(line), assetLower) {
			if looksLikeSHA256(a) {
				return a, nil
			}
			if looksLikeSHA256(b) {
				return b, nil
			}
		}
		if looksLikeSHA256(a) && strings.HasSuffix(strings.ToLower(b), strings.ToLower(assetName)) {
			return a, nil
		}
	}
	if err := sc.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("checksum entry not found for asset %s in %s", assetName, checksumURL)
}

func lookupChecksumWithFallbacks(tool, version string, vspec VerifySpec, assetName string) (string, error) {
	v := normalizeSemver(version)
	candidates := []string{vspec.ChecksumURL}

	switch tool {
	case "shfmt":
		candidates = append(candidates,
			fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/sha256sums.txt", v),
			fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/SHASUMS256.txt", v),
			fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/%s.sha256", v, assetName),
			fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/%s.sha256sum", v, assetName),
		)
	}

	var errs []string
	seen := map[string]struct{}{}
	for _, u := range candidates {
		u = strings.TrimSpace(u)
		if u == "" {
			continue
		}
		if _, ok := seen[u]; ok {
			continue
		}
		seen[u] = struct{}{}
		sum, err := lookupChecksum(u, assetName)
		if err == nil {
			return sum, nil
		}
		errs = append(errs, fmt.Sprintf("%s: %v", u, err))
	}
	return "", fmt.Errorf("all checksum URLs failed: %s", strings.Join(errs, " | "))
}

func looksLikeSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return false
		}
	}
	return true
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}

func unzipExecutable(zipPath, destExe, exeName string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()

	targetName := strings.ToLower(filepath.Base(exeName))

	for _, f := range r.File {
		if f.FileInfo().IsDir() {
			continue
		}
		if strings.ToLower(filepath.Base(f.Name)) != targetName {
			continue
		}

		if err := os.MkdirAll(filepath.Dir(destExe), 0o755); err != nil {
			return err
		}

		rc, err := f.Open()
		if err != nil {
			return err
		}

		out, err := os.OpenFile(destExe, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
		if err != nil {
			rc.Close()
			return err
		}

		_, copyErr := io.Copy(out, rc)
		closeErr := rc.Close()
		outCloseErr := out.Close()

		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		if outCloseErr != nil {
			return outCloseErr
		}

		return nil
	}

	return fmt.Errorf("executable %s not found in archive %s", exeName, zipPath)
}

func installMarkdownlintWithNPM(res *InstallResult, spec ToolSpec) error {
	npmExecutable, err := resolveNPMExecutable()
	if err != nil {
		return fmt.Errorf("npm is required for markdownlint: %w", err)
	}

	res.Backend = string(activePackageManager) + "+npm"
	res.PackageRef = fmt.Sprintf("markdownlint-cli2@%s", normalizeSemver(spec.Version))

	if err := npmInstallGlobalVersioned(npmExecutable, "markdownlint-cli2", spec.Version); err != nil {
		return fmt.Errorf("npm install failed: %w", err)
	}

	if binDir, err := npmGlobalBinDir(npmExecutable); err == nil {
		ensureDirOnPath(binDir)
	}
	ensureDirOnPath(filepath.Join(defaultScoopRoot(), "shims"))

	res.InstallOK = true
	res.VerifyMode = "version-only"

	verified, err := verifyInstalledToolVersion("markdownlint", spec.Version)
	if err != nil {
		return fmt.Errorf("version verification failed: %w", err)
	}
	if verified {
		res.VersionOK = true
	}
	res.ChecksumOK = true
	return nil
}

func installYamllintWithPip(res *InstallResult, spec ToolSpec) error {
	pythonExecutable, err := resolvePythonExecutable()
	if err != nil {
		return fmt.Errorf("python is required for yamllint: %w", err)
	}

	ensureExecutableDirOnPath(pythonExecutable)
	for _, dir := range discoverPythonScriptsDirs(pythonExecutable) {
		ensureDirOnPath(dir)
	}
	ensureDirOnPath(filepath.Join(defaultScoopRoot(), "shims"))

	res.Backend = string(activePackageManager) + "+pip"
	res.PackageRef = fmt.Sprintf("yamllint==%s", normalizeSemver(spec.Version))

	if err := pipInstallUserVersioned(pythonExecutable, "yamllint", spec.Version); err != nil {
		return fmt.Errorf("pip install failed: %w", err)
	}

	for _, dir := range discoverPythonScriptsDirs(pythonExecutable) {
		ensureDirOnPath(dir)
	}
	if dir, ok := findToolDirOnDisk("yamllint", discoverPythonScriptsDirs(pythonExecutable)); ok {
		ensureDirOnPath(dir)
	} else if dir, ok := findYamllintViaPython(pythonExecutable); ok {
		ensureDirOnPath(dir)
	}

	res.InstallOK = true
	res.VerifyMode = "version-only"
	res.ChecksumOK = true

	verified, err := verifyInstalledToolVersion("yamllint", spec.Version)
	if err != nil {
		if verifiedModule, moduleErr := verifyYamllintViaPythonModule(pythonExecutable, spec.Version); moduleErr == nil && verifiedModule {
			res.VersionOK = true
			res.VerifyMode = "version-only-module"
			return nil
		}
		return fmt.Errorf("version verification failed: %w", err)
	}
	if verified {
		res.VersionOK = true
	}
	return nil
}

func resolvePythonExecutable() (string, error) {
	for _, name := range []string{"python.exe", "python"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}
	// Scoop fallback when shim is not yet visible.
	for _, candidate := range []string{
		filepath.Join(defaultScoopRoot(), "apps", "python", "current", "python.exe"),
		filepath.Join(defaultScoopRoot(), "shims", "python.exe"),
	} {
		if fileExists(candidate) {
			ensureExecutableDirOnPath(candidate)
			return candidate, nil
		}
	}
	return "", errors.New("python executable not found in PATH")
}

func pipInstallUserVersioned(pythonExecutable, packageName, version string) error {
	target := fmt.Sprintf("%s==%s", packageName, normalizeSemver(version))
	if err := run(pythonExecutable, "-m", "pip", "install", "--user", "--disable-pip-version-check", target); err == nil {
		return nil
	}
	// Fallback: install into the active interpreter environment (scoop python Scripts).
	return run(pythonExecutable, "-m", "pip", "install", "--disable-pip-version-check", target)
}

func discoverPythonScriptsDirs(pythonExecutable string) []string {
	dirs := make([]string, 0, 8)
	seen := map[string]struct{}{}

	add := func(dir string) {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			return
		}
		// Normalize for de-dupe on Windows.
		key := strings.ToLower(filepath.Clean(dir))
		if _, ok := seen[key]; ok {
			return
		}
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			seen[key] = struct{}{}
			dirs = append(dirs, dir)
		}
	}

	// Ask Python for all plausible scripts locations.
	// NOTE: runOut uses CombinedOutput; always take the last non-empty line per path print.
	probe := `import os,sys,sysconfig,site
paths=[]
def add(p):
    if p and p not in paths:
        paths.append(p)
add(sysconfig.get_path("scripts"))
for scheme in ("nt_user","posix_user","nt","posix_prefix","osx_framework_user"):
    try:
        add(sysconfig.get_path("scripts", scheme))
    except Exception:
        pass
ub=getattr(site,"USER_BASE",None) or ""
if ub:
    add(os.path.join(ub,"Scripts"))
    add(os.path.join(ub,"bin"))
add(os.path.join(os.path.dirname(sys.executable),"Scripts"))
for p in paths:
    if p and os.path.isdir(p):
        print(p)
`
	if out, err := runOut(pythonExecutable, "-c", probe); err == nil {
		for _, line := range strings.Split(out, "\n") {
			add(strings.TrimSpace(line))
		}
	}

	// Static candidates for scoop / standard Windows layouts.
	pythonDir := filepath.Dir(pythonExecutable)
	add(filepath.Join(pythonDir, "Scripts"))
	add(filepath.Join(defaultScoopRoot(), "apps", "python", "current", "Scripts"))
	add(filepath.Join(defaultScoopRoot(), "shims"))

	if appData := strings.TrimSpace(os.Getenv("APPDATA")); appData != "" {
		// %APPDATA%\Python\Python3x\Scripts
		pythonRoot := filepath.Join(appData, "Python")
		if entries, err := os.ReadDir(pythonRoot); err == nil {
			for _, e := range entries {
				if e.IsDir() && strings.HasPrefix(strings.ToLower(e.Name()), "python") {
					add(filepath.Join(pythonRoot, e.Name(), "Scripts"))
				}
			}
		}
	}
	if localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); localAppData != "" {
		add(filepath.Join(localAppData, "Programs", "Python", "Python312", "Scripts"))
		add(filepath.Join(localAppData, "Programs", "Python", "Python311", "Scripts"))
		add(filepath.Join(localAppData, "Programs", "Python", "Python310", "Scripts"))
	}

	return dirs
}

func findToolDirOnDisk(tool string, dirs []string) (string, bool) {
	for _, dir := range dirs {
		for _, name := range []string{
			filepath.Join(dir, tool+".exe"),
			filepath.Join(dir, tool+".cmd"),
			filepath.Join(dir, tool+".bat"),
			filepath.Join(dir, tool),
		} {
			if fileExists(name) {
				return dir, true
			}
		}
	}
	return "", false
}

func findYamllintViaPython(pythonExecutable string) (string, bool) {
	// Resolve console_script entry path from the installed distribution.
	probe := `import os,sys
try:
    import yamllint
except Exception as e:
    sys.exit(1)
candidates=[]
try:
    from importlib.metadata import distribution
    dist=distribution("yamllint")
    for rec in (dist.files or []):
        s=str(rec)
        if s.endswith("yamllint.exe") or s.endswith("yamllint"):
            p=dist.locate_file(rec)
            candidates.append(str(p))
except Exception:
    pass
# common adjacent Scripts folder next to interpreter
candidates.append(os.path.join(os.path.dirname(sys.executable),"Scripts","yamllint.exe"))
for c in candidates:
    if c and os.path.isfile(c):
        print(os.path.dirname(c))
        break
`
	out, err := runOut(pythonExecutable, "-c", probe)
	if err != nil {
		return "", false
	}
	dir := lastNonEmptyLine(out)
	if dir == "" {
		return "", false
	}
	return dir, true
}

func verifyYamllintViaPythonModule(pythonExecutable, expected string) (bool, error) {
	out, err := runOut(pythonExecutable, "-m", "yamllint", "--version")
	if err != nil {
		return false, err
	}
	actual, err := firstSemver(out)
	if err != nil {
		return false, err
	}
	if normalizeSemver(actual) != normalizeSemver(expected) {
		return true, fmt.Errorf("expected=%s actual=%s", expected, actual)
	}
	return true, nil
}

func lastNonEmptyLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line != "" {
			return line
		}
	}
	return ""

}

func resolveWingetPackageID(tool, version string) (string, bool) {
	switch tool {
	case "markdownlint":
		return "markdownlint-cli2", true
	case "python":
		parts := strings.Split(normalizeSemver(version), ".")
		if len(parts) < 2 {
			return "", false
		}
		return fmt.Sprintf("Python.Python.%s.%s", parts[0], parts[1]), true
	case "nodejs":
		major, err := majorVersion(version)
		if err != nil {
			return "OpenJS.NodeJS", true
		}
		if major%2 == 0 {
			return "OpenJS.NodeJS.LTS", true
		}
		return "OpenJS.NodeJS", true
	default:
		ref, ok := wingetMap[tool]
		return ref, ok
	}
}

func verifyInstalledToolVersion(tool, expected string) (bool, error) {
	verifyFn, ok := toolVersionVerifiers[tool]
	if !ok {
		return false, nil
	}

	actual, err := verifyFn()
	if err != nil {
		return false, fmt.Errorf("tool %s is not executable after install: %w", tool, err)
	}

	if normalizeSemver(actual) != normalizeSemver(expected) {
		return true, fmt.Errorf("expected=%s actual=%s", expected, actual)
	}

	return true, nil
}

func commandVersion(name string, args ...string) (string, error) {
	exe, err := resolveToolExecutable(name)
	if err != nil {
		return "", err
	}
	out, err := runOut(exe, args...)
	if err != nil {
		return "", err
	}
	return firstSemver(out)
}

func firstSemver(s string) (string, error) {
	re := regexp.MustCompile(`(?mi)\bv?([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b`)
	m := re.FindStringSubmatch(s)
	if len(m) != 2 {
		return "", fmt.Errorf("could not parse semantic version from output: %s", strings.TrimSpace(s))
	}
	return m[1], nil
}

func majorVersion(v string) (int, error) {
	parts := strings.Split(normalizeSemver(v), ".")
	if len(parts) == 0 || parts[0] == "" {
		return 0, fmt.Errorf("invalid version: %s", v)
	}
	return strconv.Atoi(parts[0])
}

func resolveScoopExecutable() (string, bool) {
	for _, name := range []string{"scoop", "scoop.cmd"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, true
		}
	}

	for _, candidate := range scoopExecutableCandidates() {
		if fileExists(candidate) {
			ensureExecutableDirOnPath(candidate)
			return candidate, true
		}
	}

	return "", false
}

func resolveWingetExecutable() (string, bool) {
	for _, name := range []string{"winget.exe", "winget"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, true
		}
	}

	for _, candidate := range wingetExecutableCandidates() {
		if fileExists(candidate) {
			ensureExecutableDirOnPath(candidate)
			return candidate, true
		}
	}

	return "", false
}

func resolveNPMExecutable() (string, error) {
	for _, name := range []string{"npm.cmd", "npm.exe", "npm"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}
	return "", errors.New("npm executable not found in PATH")
}

func npmGlobalBinDir(npmExecutable string) (string, error) {
	out, err := runOut(npmExecutable, "bin", "-g")
	if err != nil {
		return "", err
	}
	dir := strings.TrimSpace(out)
	// npm may print extra lines; take the last non-empty line.
	lines := strings.Split(dir, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line != "" {
			dir = line
			break
		}
	}
	if dir == "" {
		return "", errors.New("empty npm global bin directory")
	}
	return dir, nil
}

func npmInstallGlobalVersioned(npmExecutable, packageName, version string) error {
	target := fmt.Sprintf("%s@%s", packageName, normalizeSemver(version))
	return run(npmExecutable, "install", "--global", target)
}

func wingetExecutableCandidates() []string {
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	userProfile := strings.TrimSpace(os.Getenv("USERPROFILE"))

	candidates := make([]string, 0, 2)
	if localAppData != "" {
		candidates = append(candidates, filepath.Join(localAppData, "Microsoft", "WindowsApps", "winget.exe"))
	}
	if userProfile != "" {
		candidates = append(candidates, filepath.Join(userProfile, "AppData", "Local", "Microsoft", "WindowsApps", "winget.exe"))
	}
	return candidates
}

func ensureDirOnPath(dir string) {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return
	}
	current := os.Getenv("PATH")
	if pathContains(current, dir) {
		// Move to front to beat stale preinstalled binaries (common on GHA images).
		_ = os.Setenv("PATH", prependPath(current, dir))
		return
	}
	if current == "" {
		_ = os.Setenv("PATH", dir)
		return
	}
	_ = os.Setenv("PATH", dir+string(os.PathListSeparator)+current)
}

func prependPath(current, dir string) string {
	dir = filepath.Clean(dir)
	parts := make([]string, 0, 32)
	parts = append(parts, dir)
	dirKey := strings.ToLower(dir)
	for _, p := range strings.Split(current, string(os.PathListSeparator)) {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if strings.ToLower(filepath.Clean(p)) == dirKey {
			continue
		}
		parts = append(parts, p)
	}
	return strings.Join(parts, string(os.PathListSeparator))
}

func ensureExecutableDirOnPath(executable string) {
	ensureDirOnPath(filepath.Dir(executable))
}

func refreshWindowsPath() {
	machine, _ := readRegExpandString(`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, "Path")
	user, _ := readRegExpandString(`HKCU\Environment`, "Path")

	parts := make([]string, 0, 64)
	seen := map[string]struct{}{}
	add := func(chunk string) {
		for _, p := range strings.Split(chunk, ";") {
			p = strings.TrimSpace(p)
			if p == "" {
				continue
			}
			key := strings.ToLower(filepath.Clean(p))
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			parts = append(parts, p)
		}
	}

	add(machine)
	add(user)
	add(os.Getenv("PATH"))

	// WinGet Links + common user-local bin dirs.
	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	if localAppData != "" {
		add(filepath.Join(localAppData, "Microsoft", "WinGet", "Links"))
		add(filepath.Join(localAppData, "Microsoft", "WindowsApps"))
	}
	add(filepath.Join(defaultScoopRoot(), "shims"))

	_ = os.Setenv("PATH", strings.Join(parts, ";"))
}

func readRegExpandString(keyName, valueName string) (string, error) {
	out, err := runOut("reg", "query", keyName, "/v", valueName)
	if err != nil {
		return "", err
	}
	// Example line: "    Path    REG_EXPAND_SZ    C:\Windows\system32;..."
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.Contains(strings.ToUpper(line), "REG_") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		idx := strings.Index(strings.ToUpper(line), "REG_")
		if idx < 0 {
			continue
		}
		rest := strings.TrimSpace(line[idx:])
		parts := strings.SplitN(rest, " ", 2)
		if len(parts) != 2 {
			continue
		}
		data := strings.TrimSpace(parts[1])
		// Drop the type token if still present.
		if i := strings.IndexAny(data, " \t"); i >= 0 {
			typeTok := strings.ToUpper(strings.TrimSpace(data[:i]))
			if strings.HasPrefix(typeTok, "REG_") {
				data = strings.TrimSpace(data[i:])
			}
		}
		return data, nil
	}
	return "", fmt.Errorf("registry value %s\\%s not found", keyName, valueName)
}

func toolExecutableNames(tool string) []string {
	switch tool {
	case "nodejs":
		return []string{"node.exe", "node"}
	case "markdownlint":
		return []string{"markdownlint-cli2.exe", "markdownlint-cli2.cmd", "markdownlint-cli2"}
	case "docker-cli":
		return []string{"docker.exe", "docker"}
	case "docker-compose":
		return []string{"docker-compose.exe", "docker-compose"}
	default:
		return []string{tool + ".exe", tool + ".cmd", tool + ".bat", tool}
	}
}

func wingetSearchDirs(tool string) []string {
	dirs := make([]string, 0, 32)
	add := func(dir string) {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			return
		}
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			dirs = append(dirs, dir)
		}
	}

	localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	programFiles := strings.TrimSpace(os.Getenv("ProgramFiles"))
	programFilesX86 := strings.TrimSpace(os.Getenv("ProgramFiles(x86)"))

	if localAppData != "" {
		add(filepath.Join(localAppData, "Microsoft", "WinGet", "Links"))
		add(filepath.Join(localAppData, "Microsoft", "WindowsApps"))
		pkgRoot := filepath.Join(localAppData, "Microsoft", "WinGet", "Packages")
		if entries, err := os.ReadDir(pkgRoot); err == nil {
			for _, e := range entries {
				if !e.IsDir() {
					continue
				}
				base := filepath.Join(pkgRoot, e.Name())
				add(base)
				add(filepath.Join(base, "bin"))
				if sub, err := os.ReadDir(base); err == nil {
					for _, s := range sub {
						if s.IsDir() {
							add(filepath.Join(base, s.Name()))
							add(filepath.Join(base, s.Name(), "bin"))
						}
					}
				}
			}
		}
	}

	for _, root := range []string{programFiles, programFilesX86} {
		if root == "" {
			continue
		}
		// Heuristic product folders.
		switch tool {
		case "terraform":
			add(filepath.Join(root, "Terraform"))
		case "nodejs":
			add(filepath.Join(root, "nodejs"))
		case "trivy":
			add(filepath.Join(root, "Trivy"))
		case "gitleaks":
			add(filepath.Join(root, "Gitleaks"))
		case "just":
			add(filepath.Join(root, "just"))
		}
	}

	add(filepath.Join(defaultScoopRoot(), "shims"))
	add(filepath.Join(defaultScoopRoot(), "apps", tool, "current"))
	return dirs
}

func ensureWingetToolOnPath(tool string) {
	refreshWindowsPath()
	names := toolExecutableNames(tool)
	// If already resolvable, nothing to do.
	for _, n := range names {
		if _, err := exec.LookPath(n); err == nil {
			return
		}
	}
	if dir, ok := findToolDirOnDiskByNames(names, wingetSearchDirs(tool)); ok {
		ensureDirOnPath(dir)
	}
}

func findToolDirOnDiskByNames(names []string, dirs []string) (string, bool) {
	for _, dir := range dirs {
		for _, name := range names {
			candidate := name
			if !filepath.IsAbs(name) {
				candidate = filepath.Join(dir, name)
			}
			if fileExists(candidate) {
				return dir, true
			}
		}
	}
	return "", false
}

// scoopAppName extracts the app leaf from a scoop ref ("main/gitleaks" -> "gitleaks").
func scoopAppName(packageRef string) string {
	packageRef = strings.TrimSpace(packageRef)
	if packageRef == "" {
		return ""
	}
	parts := strings.Split(packageRef, "/")
	return parts[len(parts)-1]
}

// ensureScoopToolOnPath makes scoop shims and the installed app directory
// resolvable via PATH for subsequent exec.LookPath / exec.Command calls.
func ensureScoopToolOnPath(packageRef, tool string) {
	for _, root := range []string{defaultScoopRoot(), globalScoopRoot()} {
		ensureDirOnPath(filepath.Join(root, "shims"))
	}

	app := scoopAppName(packageRef)
	candidates := []string{}
	if app != "" {
		candidates = append(candidates, app)
	}
	if tool != "" && !strings.EqualFold(tool, app) {
		candidates = append(candidates, tool)
	}

	for _, name := range candidates {
		for _, root := range []string{defaultScoopRoot(), globalScoopRoot()} {
			ensureDirOnPath(filepath.Join(root, "apps", name, "current"))
			// Versioned installs without a working "current" junction.
			appRoot := filepath.Join(root, "apps", name)
			if entries, err := os.ReadDir(appRoot); err == nil {
				for _, e := range entries {
					if !e.IsDir() {
						continue
					}
					dirName := e.Name()
					if strings.EqualFold(dirName, "current") {
						continue
					}
					// Only promote dirs that actually contain the binary.
					exe := filepath.Join(appRoot, dirName, name+".exe")
					if fileExists(exe) {
						ensureDirOnPath(filepath.Join(appRoot, dirName))
					}
				}
			}
		}
	}
}

// resolveToolExecutable finds a CLI on PATH, then common Scoop locations.
// Returns an absolute path suitable for exec.Command on Windows.
func resolveToolExecutable(name string) (string, error) {
	refreshWindowsPath()
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errors.New("empty tool executable name")
	}

	for _, candidate := range []string{name + ".exe", name, name + ".cmd", name + ".bat"} {
		if path, err := exec.LookPath(candidate); err == nil {
			return path, nil
		}
	}

	// Scoop fallbacks (shim + app install tree).
	for _, root := range []string{defaultScoopRoot(), globalScoopRoot()} {
		for _, candidate := range []string{
			filepath.Join(root, "shims", name+".exe"),
			filepath.Join(root, "shims", name+".cmd"),
			filepath.Join(root, "apps", name, "current", name+".exe"),
		} {
			if fileExists(candidate) {
				ensureExecutableDirOnPath(candidate)
				return candidate, nil
			}
		}

		// Scan versioned app dirs if "current" is missing.
		appRoot := filepath.Join(root, "apps", name)
		if entries, err := os.ReadDir(appRoot); err == nil {
			// Prefer highest lexical version dir as a stable-enough fallback.
			var matches []string
			for _, e := range entries {
				if !e.IsDir() || strings.EqualFold(e.Name(), "current") {
					continue
				}
				exe := filepath.Join(appRoot, e.Name(), name+".exe")
				if fileExists(exe) {
					matches = append(matches, exe)
				}
			}
			if len(matches) > 0 {
				sort.Strings(matches)
				exe := matches[len(matches)-1]
				ensureExecutableDirOnPath(exe)
				return exe, nil
			}
		}
	}
	if dir, ok := findToolDirOnDiskByNames(toolExecutableNames(name), wingetSearchDirs(name)); ok {
		for _, cand := range toolExecutableNames(name) {
			p := filepath.Join(dir, cand)
			if fileExists(p) {
				ensureDirOnPath(dir)
				return p, nil
			}
		}
	}
	return "", fmt.Errorf("executable %q not found in PATH or Scoop app dirs", name)
}

func bootstrapScoop() error {
	_ = run(scoopExecutable, "bucket", "add", "main")
	if err := run(scoopExecutable, "update"); err != nil {
		return err
	}
	return nil
}

func wingetInstallVersioned(packageID, version string) error {
	version = normalizeSemver(version)
	base := []string{
		"install",
		"--id", packageID,
		"--exact",
		"--accept-package-agreements",
		"--accept-source-agreements",
		"--disable-interactivity",
		"--silent",
		"--version", version,
	}

	if err := run(wingetExecutable, base...); err == nil {
		return nil
	} else if isWingetAlreadyInstalledError(err) {
		// Install step is OK; caller must verify the on-PATH version.
		return nil
	} else if isWingetNoPackageOrVersionError(err) {
		return err
	}

	upgrade := []string{
		"upgrade",
		"--id", packageID,
		"--exact",
		"--accept-package-agreements",
		"--accept-source-agreements",
		"--disable-interactivity",
		"--silent",
		"--version", version,
	}
	if err := run(wingetExecutable, upgrade...); err == nil || isWingetAlreadyInstalledError(err) {
		return nil
	}

	force := append(append([]string{}, base...), "--force")
	if err := run(wingetExecutable, force...); err == nil || isWingetAlreadyInstalledError(err) {
		return nil
	}

	// Preserve original exact-install failure for diagnostics.
	if err := run(wingetExecutable, base...); err != nil {
		return err
	}
	return nil
}

func isWingetAlreadyInstalledError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "0x8a15002b") ||
		strings.Contains(msg, "no available upgrade found") ||
		strings.Contains(msg, "no newer package versions are available") ||
		strings.Contains(msg, "found an existing package already installed")
}

func isWingetNoPackageOrVersionError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "0x8a150014") ||
		strings.Contains(msg, "0x8a150017") ||
		strings.Contains(msg, "no package found matching input criteria") ||
		strings.Contains(msg, "no version found matching")
}

func scoopInstallVersioned(app, version string) error {
	target := fmt.Sprintf("%s@%s", app, normalizeSemver(version))
	if err := run(scoopExecutable, "install", target); err == nil {
		return nil
	}

	if err := run(scoopExecutable, "install", app); err != nil {
		return err
	}

	installed, err := scoopCurrentVersion(app)
	if err != nil {
		return err
	}
	if normalizeSemver(installed) != normalizeSemver(version) {
		return fmt.Errorf("installed version mismatch for %s: expected=%s actual=%s", app, version, installed)
	}
	return nil
}

func scoopCurrentVersion(app string) (string, error) {
	out, err := runOut(scoopExecutable, "info", app)
	if err != nil {
		return "", err
	}
	re := regexp.MustCompile(`(?mi)^Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$`)
	m := re.FindStringSubmatch(out)
	if len(m) != 2 {
		return "", fmt.Errorf("could not parse installed version from scoop info for %s", app)
	}
	return m[1], nil
}

func verifyInstalledArtifactViaScoopCache(app string, spec VerifySpec) error {
	cacheDir, err := scoopCacheDir()
	if err != nil {
		return err
	}

	cacheFile, err := findFileContains(cacheDir, spec.AssetNamePattern)
	if err != nil {
		return fmt.Errorf("cache artifact not found (pattern=%s): %w", spec.AssetNamePattern, err)
	}

	expected, err := fetchExpectedChecksum(spec.ChecksumURL, filepath.Base(cacheFile), spec.AssetNamePattern)
	if err != nil {
		return err
	}

	actual, err := fileSHA256(cacheFile)
	if err != nil {
		return err
	}

	if !strings.EqualFold(expected, actual) {
		return fmt.Errorf("checksum mismatch app=%s file=%s expected=%s actual=%s", app, cacheFile, expected, actual)
	}
	return nil
}

func scoopCacheDir() (string, error) {
	candidates := []string{
		filepath.Join(defaultScoopRoot(), "cache"),
		filepath.Join(globalScoopRoot(), "cache"),
	}
	for _, dir := range candidates {
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			return dir, nil
		}
	}
	return "", fmt.Errorf("scoop cache dir not found in candidates: %s", strings.Join(candidates, ", "))
}

func findFileContains(root, needle string) (string, error) {
	var found string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if strings.Contains(strings.ToLower(filepath.Base(path)), strings.ToLower(needle)) {
			found = path
			return io.EOF
		}
		return nil
	})
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	if found == "" {
		return "", errors.New("no file matched")
	}
	return found, nil
}

func fetchExpectedChecksum(checksumURL, cacheBaseName, assetNamePattern string) (string, error) {
	body, err := httpGet(checksumURL)
	if err != nil {
		return "", fmt.Errorf("download checksum file failed: %w", err)
	}

	for _, candidate := range []string{assetNamePattern, cacheBaseName} {
		sha, ok := parseChecksumForAsset(body, candidate)
		if ok {
			return sha, nil
		}
	}

	return "", fmt.Errorf("could not find checksum entry for assets (%s / %s)", assetNamePattern, cacheBaseName)
}

func parseChecksumForAsset(content, asset string) (string, bool) {
	asset = regexp.QuoteMeta(asset)

	re1 := regexp.MustCompile(`(?mi)^([a-f0-9]{64})\s+\*?` + asset + `\s*$`)
	if m := re1.FindStringSubmatch(content); len(m) == 2 {
		return strings.ToLower(m[1]), true
	}

	re2 := regexp.MustCompile(`(?mi)^SHA256\(` + asset + `\)\s*=\s*([a-f0-9]{64})\s*$`)
	if m := re2.FindStringSubmatch(content); len(m) == 2 {
		return strings.ToLower(m[1]), true
	}

	return "", false
}

func httpGet(url string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), httpTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("http status=%d url=%s", resp.StatusCode, url)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func parseToolVersions(path string) (map[string]ToolSpec, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	out := map[string]ToolSpec{}
	sc := bufio.NewScanner(f)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) < 2 {
			return nil, fmt.Errorf("invalid .tool-versions line %d: %q", lineNo, line)
		}
		out[parts[0]] = ToolSpec{Name: parts[0], Version: parts[1]}
	}
	return out, sc.Err()
}

func parseGoVersionFromGoMod(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	re := regexp.MustCompile(`(?m)^go\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$`)
	m := re.FindStringSubmatch(string(b))
	if len(m) != 2 {
		return "", errors.New("go directive not found in go.mod")
	}
	return m[1], nil
}

func validateTerraformMirror(path, expected string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	actual := strings.TrimSpace(string(b))
	if normalizeSemver(actual) != normalizeSemver(expected) {
		return fmt.Errorf(".terraform-version mismatch: expected=%s actual=%s", expected, actual)
	}
	return nil
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v failed: %v | output=%s", name, args, err, string(out))
	}
	return nil
}

func runOut(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %v failed: %v | output=%s", name, args, err, string(out))
	}
	return string(out), nil
}

func defaultScoopRoot() string {
	if custom := strings.TrimSpace(os.Getenv("SCOOP")); custom != "" {
		return custom
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.Getenv("USERPROFILE"), "scoop")
	}
	return filepath.Join(home, "scoop")
}

func globalScoopRoot() string {
	if custom := strings.TrimSpace(os.Getenv("SCOOP_GLOBAL")); custom != "" {
		return custom
	}
	programData := strings.TrimSpace(os.Getenv("ProgramData"))
	if programData == "" {
		programData = `C:\ProgramData`
	}
	return filepath.Join(programData, "scoop")
}

func scoopExecutableCandidates() []string {
	roots := []string{defaultScoopRoot(), globalScoopRoot()}
	candidates := make([]string, 0, len(roots)*3)
	for _, root := range roots {
		candidates = append(candidates,
			filepath.Join(root, "shims", "scoop.cmd"),
			filepath.Join(root, "shims", "scoop.ps1"),
			filepath.Join(root, "apps", "scoop", "current", "bin", "scoop.ps1"),
		)
	}
	return candidates
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

func pathContains(pathValue, entry string) bool {
	for _, item := range filepath.SplitList(pathValue) {
		if strings.EqualFold(strings.TrimSpace(item), strings.TrimSpace(entry)) {
			return true
		}
	}
	return false
}

func repoRoot() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	cur := wd
	for {
		if _, err := os.Stat(filepath.Join(cur, ".git")); err == nil {
			return cur, nil
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return "", errors.New("repo root not found")
		}
		cur = parent
	}
}

func sortedKeys(m map[string]ToolSpec) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		pi, iok := toolInstallPriority[keys[i]]
		pj, jok := toolInstallPriority[keys[j]]

		switch {
		case iok && jok && pi != pj:
			return pi < pj
		case iok != jok:
			return iok
		default:
			return keys[i] < keys[j]
		}
	})
	return keys
}

func normalizeSemver(v string) string {
	return strings.TrimPrefix(strings.TrimSpace(v), "v")
}

func printSummary(results []InstallResult, tfVersion, goVersion string) {
	fmt.Println("INSTALL_TOOLS_WINDOWS_SUMMARY_START")
	fmt.Printf("package_manager=%s\n", activePackageManager)
	fmt.Printf("fallback_package_manager=%s\n", packageManagerWinget)
	fmt.Printf("terraform_version=%s\n", tfVersion)
	fmt.Printf("go_version_from_go_mod=%s\n", goVersion)

	ok, skipped, failed := 0, 0, 0
	for _, r := range results {
		fmt.Printf("tool=%s version=%s backend=%s package_ref=%s status=%s install_ok=%t version_ok=%t checksum_ok=%t verify_mode=%s\n",
			r.Tool, r.Version, r.Backend, r.PackageRef, r.Status, r.InstallOK, r.VersionOK, r.ChecksumOK, r.VerifyMode)
		if r.Error != nil {
			fmt.Printf("tool=%s error=%q\n", r.Tool, r.Error.Error())
		}
		switch r.Status {
		case "ok":
			ok++
		case "skipped":
			skipped++
		case "failed":
			failed++
		}
	}

	fmt.Printf("ok=%d skipped=%d failed=%d\n", ok, skipped, failed)
	fmt.Println("INSTALL_TOOLS_WINDOWS_SUMMARY_END")
}

func fatal(stage string, err error) {
	fmt.Printf("stage=%s status=failed error=%q\n", stage, err.Error())
	os.Exit(1)
}
