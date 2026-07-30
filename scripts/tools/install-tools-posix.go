//go:build !windows

package main

import (
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
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

type ToolSpec struct {
	Name    string
	Version string
}

type VerifySpec struct {
	AssetNamePattern string
	ChecksumURL      string
}

type InstallResult struct {
	Tool       string
	Version    string
	Status     string // ok|skipped|failed
	Backend    string
	PackageRef string

	InstallOK  bool
	VersionOK  bool
	ChecksumOK bool
	VerifyMode string // checksum|version-only|install-only|skipped

	Warning error
	Error   error
}

type PackageManager string

type PlatformSpec struct {
	GOOS   string
	GOARCH string
}

const (
	httpTimeout = 90 * time.Second

	packageManagerNone PackageManager = ""
	packageManagerASDF PackageManager = "asdf"
	packageManagerMise PackageManager = "mise"
)

var (
	activePackageManager = packageManagerNone
	asdfExecutable       = "asdf"
	miseExecutable       = "mise"

	toolVersionVerifiers = map[string]func() (string, error){
		"terraform":      func() (string, error) { return commandVersion("terraform", "version") },
		"tflint":         func() (string, error) { return commandVersion("tflint", "--version") },
		"terraform-docs": func() (string, error) { return commandVersion("terraform-docs", "--version") },
		"trivy":          func() (string, error) { return commandVersion("trivy", "--version") },
		"checkov":        func() (string, error) { return commandVersion("checkov", "--version") },
		"python":         func() (string, error) { return commandVersion("python", "--version") },
		"nodejs":         func() (string, error) { return commandVersion("node", "--version") },
		"pre-commit":     func() (string, error) { return commandVersion("pre-commit", "--version") },
		"golangci-lint":  func() (string, error) { return commandVersion("golangci-lint", "version") },
		"markdownlint":   func() (string, error) { return commandVersion("markdownlint-cli2", "--version") },
		"yamllint":       func() (string, error) { return commandVersion("yamllint", "--version") },
		"actionlint":     func() (string, error) { return commandVersion("actionlint", "-version") },
		"task":           func() (string, error) { return commandVersion("task", "--version") },
		"just":           func() (string, error) { return commandVersion("just", "--version") },
		"gitleaks":       func() (string, error) { return commandVersion("gitleaks", "version") },
		"docker-cli":     func() (string, error) { return commandVersion("docker", "--version") },
		"docker-compose": verifyDockerComposeVersion,
		"golang":         verifyGoVersion,
		"shfmt":          func() (string, error) { return commandVersion("shfmt", "--version") },
	}

	verifyBuilders = map[string]func(version string) (VerifySpec, error){
		"terraform": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			osPart, archPart, err := terraformPlatformStrings(p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: fmt.Sprintf("terraform_%s_%s_%s.zip", v, osPart, archPart),
				ChecksumURL:      fmt.Sprintf("https://releases.hashicorp.com/terraform/%s/terraform_%s_SHA256SUMS", v, v),
			}, nil
		},
		"tflint": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := tflintAssetName(p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/terraform-linters/tflint/releases/download/v%s/checksums.txt", v),
			}, nil
		},
		"terraform-docs": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := terraformDocsAssetName(v, p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/terraform-docs/terraform-docs/releases/download/v%s/terraform-docs-v%s.sha256sum", v, v),
			}, nil
		},
		"trivy": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := trivyAssetName(v, p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/aquasecurity/trivy/releases/download/v%s/trivy_%s_checksums.txt", v, v),
			}, nil
		},
		"golangci-lint": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := golangciLintAssetName(v, p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/golangci/golangci-lint/releases/download/v%s/golangci-lint-%s-checksums.txt", v, v),
			}, nil
		},
		"actionlint": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := actionlintAssetName(v, p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/rhysd/actionlint/releases/download/v%s/actionlint_%s_checksums.txt", v, v),
			}, nil
		},
		"gitleaks": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := gitleaksAssetName(v, p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/gitleaks/gitleaks/releases/download/v%s/gitleaks_%s_checksums.txt", v, v),
			}, nil
		},
		"shfmt": func(v string) (VerifySpec, error) {
			v = normalizeSemver(v)
			p, err := currentPlatform()
			if err != nil {
				return VerifySpec{}, err
			}
			asset, err := shfmtAssetName(v, p)
			if err != nil {
				return VerifySpec{}, err
			}
			return VerifySpec{
				AssetNamePattern: asset,
				ChecksumURL:      fmt.Sprintf("https://github.com/mvdan/sh/releases/download/v%s/sha256sums.txt", v),
			}, nil
		},
	}
)

func main() {
	root, err := repoRoot()
	if err != nil {
		fatal("INIT", err)
	}

	if _, err := currentPlatform(); err != nil {
		fatal("VALIDATE_PLATFORM", err)
	}

	toolVersionsPath := filepath.Join(root, "tooling", ".tool-versions")
	goModPath := filepath.Join(root, "go.mod")
	tfMirrorPath := filepath.Join(root, "tooling", ".terraform-version")

	tools, err := parseToolVersions(toolVersionsPath)
	if err != nil {
		fatal("PARSE_TOOL_VERSIONS", err)
	}

	goVersion, err := parseGoVersionFromGoMod(goModPath)
	if err != nil {
		fatal("PARSE_GO_MOD", err)
	}

	if gv, ok := tools["golang"]; ok {
		if !versionMatchesExpected(gv.Version, goVersion) {
			fatal("VALIDATE_GO_SOT", fmt.Errorf("golang mismatch: tooling/.tool-versions=%s go.mod=%s", gv.Version, goVersion))
		}
	}

	tfSpec, ok := tools["terraform"]
	if !ok {
		fatal("VALIDATE_TERRAFORM", errors.New("terraform not found in tooling/.tool-versions"))
	}
	if err := validateTerraformMirror(tfMirrorPath, tfSpec.Version); err != nil {
		fatal("VALIDATE_TERRAFORM_MIRROR", err)
	}

	// go.mod is the only source of truth for Go. We synthesize a tool entry from it.
	tools["golang"] = ToolSpec{Name: "golang", Version: goVersion}

	if err := ensurePackageManager(); err != nil {
		fatal("ENSURE_PACKAGE_MANAGER", err)
	}
	if err := bootstrapPackageManager(); err != nil {
		fatal("BOOTSTRAP_PACKAGE_MANAGER", err)
	}
	if err := ensurePackageManagerOnPATH(); err != nil {
		fatal("ENSURE_PACKAGE_MANAGER_PATH", err)
	}

	keys := sortedKeys(tools)
	results := make([]InstallResult, 0, len(keys))

	for _, k := range keys {
		spec := tools[k]
		res := InstallResult{
			Tool:       k,
			Version:    spec.Version,
			Status:     "failed",
			Backend:    string(activePackageManager),
			PackageRef: packageRefForTool(k),
		}

		if err := installTool(&res, spec); err != nil {
			res.Error = err
			results = append(results, res)
			continue
		}

		res.Status = "ok"
		results = append(results, res)
	}

	printSummary(results, tfSpec.Version, goVersion)

	for _, r := range results {
		if r.Status == "failed" {
			os.Exit(1)
		}
	}
}

func currentPlatform() (PlatformSpec, error) {
	p := PlatformSpec{
		GOOS:   runtime.GOOS,
		GOARCH: runtime.GOARCH,
	}

	if p.GOOS != "linux" && p.GOOS != "darwin" {
		return PlatformSpec{}, fmt.Errorf("unsupported POSIX platform: %s", p.GOOS)
	}

	switch p.GOARCH {
	case "amd64", "arm64":
		return p, nil
	default:
		return PlatformSpec{}, fmt.Errorf("unsupported architecture: %s", p.GOARCH)
	}
}

func terraformPlatformStrings(p PlatformSpec) (osPart, archPart string, err error) {
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", "", fmt.Errorf("unsupported terraform os: %s", p.GOOS)
	}

	switch p.GOARCH {
	case "amd64":
		archPart = "amd64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", "", fmt.Errorf("unsupported terraform arch: %s", p.GOARCH)
	}

	return osPart, archPart, nil
}

func tflintAssetName(p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", fmt.Errorf("unsupported tflint os: %s", p.GOOS)
	}

	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "amd64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", fmt.Errorf("unsupported tflint arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("tflint_%s_%s.zip", osPart, archPart), nil
}

func terraformDocsAssetName(version string, p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", fmt.Errorf("unsupported terraform-docs os: %s", p.GOOS)
	}

	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "amd64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", fmt.Errorf("unsupported terraform-docs arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("terraform-docs-v%s-%s-%s.tar.gz", version, osPart, archPart), nil
}

func trivyAssetName(version string, p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "Linux"
	case "darwin":
		osPart = "macOS"
	default:
		return "", fmt.Errorf("unsupported trivy os: %s", p.GOOS)
	}

	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "64bit"
	case "arm64":
		archPart = "ARM64"
	default:
		return "", fmt.Errorf("unsupported trivy arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("trivy_%s_%s-%s.tar.gz", version, osPart, archPart), nil
}

func golangciLintAssetName(version string, p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", fmt.Errorf("unsupported golangci-lint os: %s", p.GOOS)
	}

	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "amd64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", fmt.Errorf("unsupported golangci-lint arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("golangci-lint-%s-%s-%s.tar.gz", version, osPart, archPart), nil
}

func actionlintAssetName(version string, p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", fmt.Errorf("unsupported actionlint os: %s", p.GOOS)
	}

	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "amd64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", fmt.Errorf("unsupported actionlint arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("actionlint_%s_%s_%s.tar.gz", version, osPart, archPart), nil
}

func gitleaksAssetName(version string, p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", fmt.Errorf("unsupported gitleaks os: %s", p.GOOS)
	}

	// Upstream release assets use x64 (not amd64) and arm64.
	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "x64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", fmt.Errorf("unsupported gitleaks arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("gitleaks_%s_%s_%s.tar.gz", version, osPart, archPart), nil
}

func shfmtAssetName(version string, p PlatformSpec) (string, error) {
	var osPart string
	switch p.GOOS {
	case "linux":
		osPart = "linux"
	case "darwin":
		osPart = "darwin"
	default:
		return "", fmt.Errorf("unsupported shfmt os: %s", p.GOOS)
	}

	var archPart string
	switch p.GOARCH {
	case "amd64":
		archPart = "amd64"
	case "arm64":
		archPart = "arm64"
	default:
		return "", fmt.Errorf("unsupported shfmt arch: %s", p.GOARCH)
	}

	return fmt.Sprintf("shfmt_v%s_%s_%s", version, osPart, archPart), nil
}

func ensurePackageManager() error {
	if path, err := exec.LookPath("asdf"); err == nil {
		asdfExecutable = path
		activePackageManager = packageManagerASDF
		return nil
	}

	if path, err := exec.LookPath("mise"); err == nil {
		miseExecutable = path
		activePackageManager = packageManagerMise
		return nil
	}

	return errors.New("no supported POSIX package manager found; install asdf or mise first")
}

func bootstrapPackageManager() error {
	switch activePackageManager {
	case packageManagerASDF:
		prependPATH(
			filepath.Join(defaultASDFRoot(), "shims"),
			filepath.Join(defaultASDFRoot(), "bin"),
		)
		return nil
	case packageManagerMise:
		if err := ensureMiseOnPATH(); err != nil {
			return err
		}
		return nil
	default:
		return fmt.Errorf("unsupported package manager: %s", activePackageManager)
	}
}

func installTool(res *InstallResult, spec ToolSpec) error {
	switch activePackageManager {
	case packageManagerASDF:
		if err := installWithASDF(res, spec); err != nil {
			return err
		}
	case packageManagerMise:
		if err := installWithMise(res, spec); err != nil {
			return err
		}
	default:
		return fmt.Errorf("no active package manager selected")
	}

	verified, err := verifyInstalledToolVersion(spec.Name, spec.Version)
	if err != nil {
		return fmt.Errorf("version verification failed: %w", err)
	}
	if verified {
		res.VersionOK = true
		if res.VerifyMode == "" || res.VerifyMode == "install-only" {
			res.VerifyMode = "version-only"
		}
	}

	if builder, ok := verifyBuilders[spec.Name]; ok {
		vs, err := builder(spec.Version)
		if err != nil {
			return fmt.Errorf("checksum verify spec failed: %w", err)
		}
		if err := verifyInstalledArtifactChecksum(spec.Name, spec.Version, vs); err == nil {
			res.ChecksumOK = true
			res.VerifyMode = "checksum"
		} else {
			res.ChecksumOK = res.VersionOK
			if res.VerifyMode == "" {
				res.VerifyMode = "version-only"
			}
			res.Warning = fmt.Errorf("non-fatal checksum cache verification skipped: %w", err)
		}
	} else {
		res.ChecksumOK = res.VersionOK
		if res.VerifyMode == "" {
			res.VerifyMode = "version-only"
		}
	}

	return nil
}

func installWithASDF(res *InstallResult, spec ToolSpec) error {
	backendTool := backendToolName(activePackageManager, spec.Name)

	if err := asdfEnsurePlugin(backendTool); err != nil {
		return err
	}
	if spec.Name == "nodejs" {
		if err := asdfPrepareNodejsPlugin(); err != nil {
			res.Warning = fmt.Errorf("nodejs plugin keyring bootstrap skipped: %w", err)
		}
	}

	if err := run(asdfExecutable, "install", backendTool, normalizeSemver(spec.Version)); err != nil {
		return fmt.Errorf("asdf install failed: %w", err)
	}
	_ = run(asdfExecutable, "reshim", backendTool)

	res.InstallOK = true
	res.PackageRef = backendTool
	res.VerifyMode = "install-only"
	return nil
}

func installWithMise(res *InstallResult, spec ToolSpec) error {
	backendTool := backendToolName(activePackageManager, spec.Name)
	target := fmt.Sprintf("%s@%s", backendTool, normalizeSemver(spec.Version))

	if err := runWithEnv(miseInstallEnv(), miseExecutable, "install", target); err != nil {
		return fmt.Errorf("mise install failed: %w", err)
	}

	_ = runWithEnv(miseInstallEnv(), miseExecutable, "use", "-g", target)
	if err := ensurePackageManagerOnPATH(); err != nil {
		return err
	}
	_ = runWithEnv(miseInstallEnv(), miseExecutable, "reshim")
	if err := ensurePackageManagerOnPATH(); err != nil {
		return err
	}

	res.InstallOK = true
	res.PackageRef = backendTool
	res.VerifyMode = "install-only"
	return nil
}

func miseInstallEnv() []string {
	env := os.Environ()
	// mise 2026.x fails older CPython builds without GitHub attestations (common under act).
	env = append(env,
		"MISE_PYTHON_GITHUB_ATTESTATIONS=false",
		"MISE_YES=1",
		"MISE_NOT_FOUND_AUTO_INSTALL=0",
	)
	if os.Getenv("CI") == "" {
		env = append(env, "CI=true")
	}
	// Avoid interactive trust prompts on mise.toml in CI clones.
	if os.Getenv("MISE_TRUSTED_CONFIG_PATHS") == "" {
		if root, err := os.Getwd(); err == nil {
			env = append(env, "MISE_TRUSTED_CONFIG_PATHS="+root)
		}
	}
	return env
}

func backendToolName(pm PackageManager, tool string) string {
	switch tool {
	case "markdownlint":
		// .tool-versions key is markdownlint; package/plugin/binary ecosystem uses markdownlint-cli2.
		return "markdownlint-cli2"
	case "golang":
		if pm == packageManagerMise {
			return "go"
		}
		return tool
	case "nodejs":
		if pm == packageManagerMise {
			return "node"
		}
		return tool
	default:
		return tool
	}
}

func asdfEnsurePlugin(tool string) error {
	listOutput, err := runOut(asdfExecutable, "plugin", "list")
	if err == nil {
		for _, line := range strings.Split(listOutput, "\n") {
			if strings.TrimSpace(line) == tool {
				return nil
			}
		}
	}

	err = run(asdfExecutable, "plugin", "add", tool)
	if err == nil {
		return nil
	}

	alreadyInstalledMarkers := []string{
		"plugin named",
		"already added",
		"already exists",
	}
	for _, marker := range alreadyInstalledMarkers {
		if strings.Contains(strings.ToLower(err.Error()), marker) {
			return nil
		}
	}
	return fmt.Errorf("asdf plugin add failed for %s: %w", tool, err)
}

func asdfPrepareNodejsPlugin() error {
	pluginRoot := filepath.Join(defaultASDFRoot(), "plugins", "nodejs")
	importScript := filepath.Join(pluginRoot, "bin", "import-release-team-keyring")
	if !fileExists(importScript) {
		return fmt.Errorf("nodejs import script not found: %s", importScript)
	}
	return run("bash", importScript)
}

func verifyInstalledToolVersion(tool, expected string) (bool, error) {
	verifyFn, ok := toolVersionVerifiers[tool]
	if !ok {
		return false, nil
	}
	_ = ensurePackageManagerOnPATH()

	actual, err := verifyFn()
	if err != nil {
		switch activePackageManager {
		case packageManagerMise:
			_ = runWithEnv(miseInstallEnv(), miseExecutable, "reshim")
		case packageManagerASDF:
			_ = run(asdfExecutable, "reshim")
		}
		_ = ensurePackageManagerOnPATH()
		actual, err = verifyFn()
		if err != nil {
			return false, err
		}
	}
	if !versionMatchesExpectedForTool(tool, expected, actual) {
		return true, fmt.Errorf("expected=%s actual=%s", expected, actual)
	}
	return true, nil
}

func verifyDockerComposeVersion() (string, error) {
	if _, err := exec.LookPath("docker-compose"); err == nil {
		return commandVersion("docker-compose", "version")
	}
	return commandVersion("docker", "compose", "version")
}

func verifyGoVersion() (string, error) {
	out, err := runOut("go", "version")
	if err != nil {
		return "", err
	}
	re := regexp.MustCompile(`(?i)\bgo([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b`)
	if m := re.FindStringSubmatch(out); len(m) == 2 {
		return m[1], nil
	}
	// Fallback for atypical outputs (still prefer full X.Y.Z when present).
	return firstSemver(out)
}

func versionMatchesExpectedForTool(tool, expected, actual string) bool {
	switch tool {
	case "task":
		return semverCompatible(expected, actual, compatMinor)
	case "docker-compose":
		return semverCompatible(expected, actual, compatPatch)
	default:
		return versionMatchesExpected(expected, actual)
	}
}

type semverCompat int

const (
	compatExact semverCompat = iota
	compatPatch              // major.minor match; patch may differ
	compatMinor              // major match; minor/patch may differ
)

func versionMatchesExpected(expected, actual string) bool {
	expected = normalizeSemver(expected)
	actual = normalizeSemver(actual)

	if expected == actual {
		return true
	}

	expectedParts := strings.Split(expected, ".")
	actualParts := strings.Split(actual, ".")

	if len(expectedParts) == 0 || len(actualParts) == 0 || len(expectedParts) > len(actualParts) {
		return false
	}

	for i := range expectedParts {
		if expectedParts[i] != actualParts[i] {
			return false
		}
	}
	return true
}

var semverCoreRE = regexp.MustCompile(`^(\d+)(?:\.(\d+))?(?:\.(\d+))?`)

func parseSemverCore(v string) (major, minor, patch int, ok bool) {
	v = normalizeSemver(v)
	m := semverCoreRE.FindStringSubmatch(v)
	if m == nil {
		return 0, 0, 0, false
	}
	var err error
	major, err = strconv.Atoi(m[1])
	if err != nil {
		return 0, 0, 0, false
	}
	if m[2] != "" {
		minor, err = strconv.Atoi(m[2])
		if err != nil {
			return 0, 0, 0, false
		}
	}
	if m[3] != "" {
		patch, err = strconv.Atoi(m[3])
		if err != nil {
			return 0, 0, 0, false
		}
	}
	return major, minor, patch, true
}

func semverCompatible(expected, actual string, mode semverCompat) bool {
	eMaj, eMin, ePat, eOK := parseSemverCore(expected)
	aMaj, aMin, aPat, aOK := parseSemverCore(actual)
	if !eOK || !aOK {
		return versionMatchesExpected(expected, actual)
	}
	switch mode {
	case compatPatch:
		return eMaj == aMaj && eMin == aMin
	case compatMinor:
		return eMaj == aMaj
	default:
		return eMaj == aMaj && eMin == aMin && ePat == aPat
	}
}

var _ = compatExact

func verifyInstalledArtifactChecksum(tool, version string, spec VerifySpec) error {
	cacheRoots := checksumSearchRoots(tool, version)
	if len(cacheRoots) == 0 {
		return errors.New("no download cache roots discovered")
	}

	cacheFile, err := findFileContainsAny(cacheRoots, spec.AssetNamePattern)
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
		return fmt.Errorf("checksum mismatch tool=%s file=%s expected=%s actual=%s", tool, cacheFile, expected, actual)
	}
	return nil
}

func checksumSearchRoots(tool, version string) []string {
	version = normalizeSemver(version)
	backendTool := backendToolName(activePackageManager, tool)
	roots := make([]string, 0, 12)

	switch activePackageManager {
	case packageManagerASDF:
		base := filepath.Join(defaultASDFRoot(), "downloads", backendTool)
		roots = append(roots,
			base,
			filepath.Join(base, version),
		)
	case packageManagerMise:
		dataBase := filepath.Join(defaultMiseDataDir(), "downloads", backendTool)
		cacheBase := filepath.Join(defaultMiseCacheDir(), "downloads", backendTool)
		roots = append(roots,
			dataBase,
			filepath.Join(dataBase, version),
			cacheBase,
			filepath.Join(cacheBase, version),
		)
	}

	return existingDirs(roots)
}

func packageRefForTool(tool string) string {
	return backendToolName(activePackageManager, tool)
}

func parseToolVersions(path string) (map[string]ToolSpec, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	out := make(map[string]ToolSpec)
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

		name := strings.TrimSpace(parts[0])
		version := strings.TrimSpace(parts[1])
		out[name] = ToolSpec{Name: name, Version: version}
	}

	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
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
	if !versionMatchesExpected(expected, actual) {
		return fmt.Errorf(".terraform-version mismatch: expected=%s actual=%s", expected, actual)
	}
	return nil
}

func commandVersion(name string, args ...string) (string, error) {
	out, err := runOut(name, args...)
	if err != nil {
		return "", err
	}
	return firstSemver(out)
}

func firstSemver(s string) (string, error) {
	re := regexp.MustCompile(`(?mi)(?:\bgo)?v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)`)
	matches := re.FindAllStringSubmatch(s, -1)
	if len(matches) == 0 {
		return "", fmt.Errorf("could not parse semantic version from output: %s", strings.TrimSpace(s))
	}
	best := ""
	bestParts := -1
	for _, m := range matches {
		if len(m) < 2 {
			continue
		}
		cand := normalizeSemver(m[1])
		parts := strings.Count(cand, ".") + 1
		if parts > bestParts || (parts == bestParts && best == "") {
			best = cand
			bestParts = parts
		}
	}
	if best == "" {
		return "", fmt.Errorf("could not parse semantic version from output: %s", strings.TrimSpace(s))
	}
	return best, nil
}

func run(name string, args ...string) error {
	return runWithEnv(os.Environ(), name, args...)
}

func runWithEnv(env []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v failed: %v | output=%s", name, args, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func runOut(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Env = os.Environ()
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %v failed: %v | output=%s", name, args, err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func ensurePackageManagerOnPATH() error {
	switch activePackageManager {
	case packageManagerMise:
		return ensureMiseOnPATH()
	case packageManagerASDF:
		prependPATH(
			filepath.Join(defaultASDFRoot(), "shims"),
			filepath.Join(defaultASDFRoot(), "bin"),
		)
		return nil
	default:
		return nil
	}
}

func ensureMiseOnPATH() error {
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}

	candidates := []string{
		filepath.Join(defaultMiseDataDir(), "shims"),
		filepath.Join(home, ".local", "share", "mise", "shims"),
		filepath.Join(home, ".mise", "shims"),
		filepath.Join(home, ".local", "bin"),
	}

	for _, args := range [][]string{
		{"bin-paths"},
		{"bin-path"},
	} {
		if out, err := runOut(miseExecutable, args...); err == nil {
			for _, line := range strings.Split(out, "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					candidates = append(candidates, line)
				}
			}
			break
		}
	}

	// Apply env exports (PATH, MISE_*); ignore failure on older mise.
	if out, err := runOut(miseExecutable, "env", "-s", "bash"); err == nil {
		applyExportLines(out)
	}

	prependPATH(candidates...)
	return nil
}

func prependPATH(dirs ...string) {
	seen := make(map[string]struct{})
	ordered := make([]string, 0, len(dirs))

	for _, d := range dirs {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		if abs, err := filepath.Abs(d); err == nil {
			d = abs
		}
		if _, ok := seen[d]; ok {
			continue
		}
		if !dirExists(d) {
			continue
		}
		seen[d] = struct{}{}
		ordered = append(ordered, d)
	}
	if len(ordered) == 0 {
		return
	}

	final := make([]string, 0, len(ordered)+8)
	final = append(final, ordered...)
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		final = append(final, p)
	}
	_ = os.Setenv("PATH", strings.Join(final, string(os.PathListSeparator)))
}

func applyExportLines(script string) {
	sc := bufio.NewScanner(strings.NewReader(script))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "export ") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		if len(v) >= 2 {
			if (v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'') {
				v = v[1 : len(v)-1]
			}
		}
		if k != "" {
			_ = os.Setenv(k, v)
		}
	}
}

func fetchExpectedChecksum(checksumURL, cacheBaseName, assetNamePattern string) (string, error) {
	body, err := httpGet(checksumURL)
	if err != nil {
		return "", fmt.Errorf("download checksum file failed: %w", err)
	}

	for _, candidate := range []string{assetNamePattern, cacheBaseName} {
		if sha, ok := parseChecksumForAsset(body, candidate); ok {
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

func findFileContainsAny(roots []string, needle string) (string, error) {
	for _, root := range roots {
		if !dirExists(root) {
			continue
		}
		p, err := findFileContains(root, needle)
		if err == nil {
			return p, nil
		}
	}
	return "", errors.New("no file matched")
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
	sort.Strings(keys)
	return keys
}

func normalizeSemver(v string) string {
	v = strings.TrimSpace(v)
	v = strings.TrimPrefix(v, "v")
	v = strings.TrimPrefix(v, "V")
	if i := strings.Index(v, "+"); i >= 0 {
		v = v[:i]
	}
	return strings.TrimSpace(v)
}

func defaultASDFRoot() string {
	if v := strings.TrimSpace(os.Getenv("ASDF_DATA_DIR")); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.Getenv("HOME"), ".asdf")
	}
	return filepath.Join(home, ".asdf")
}

func defaultMiseDataDir() string {
	if v := strings.TrimSpace(os.Getenv("MISE_DATA_DIR")); v != "" {
		return v
	}
	if xdg := strings.TrimSpace(os.Getenv("XDG_DATA_HOME")); xdg != "" {
		return filepath.Join(xdg, "mise")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.Getenv("HOME"), ".local", "share", "mise")
	}
	return filepath.Join(home, ".local", "share", "mise")
}

func defaultMiseCacheDir() string {
	if xdg := strings.TrimSpace(os.Getenv("XDG_CACHE_HOME")); xdg != "" {
		return filepath.Join(xdg, "mise")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.Getenv("HOME"), ".cache", "mise")
	}
	return filepath.Join(home, ".cache", "mise")
}

func existingDirs(paths []string) []string {
	out := make([]string, 0, len(paths))
	seen := make(map[string]struct{}, len(paths))
	for _, p := range paths {
		if p == "" {
			continue
		}
		if _, ok := seen[p]; ok {
			continue
		}
		if dirExists(p) {
			out = append(out, p)
			seen[p] = struct{}{}
		}
	}
	return out
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.IsDir()
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

func printSummary(results []InstallResult, terraformVersion, goVersion string) {
	fmt.Println("INSTALL_TOOLS_POSIX_SUMMARY_START")
	fmt.Printf("package_manager=%s\n", activePackageManager)
	fmt.Printf("terraform_version=%s\n", terraformVersion)
	fmt.Printf("go_version_from_go_mod=%s\n", goVersion)

	okCount := 0
	skippedCount := 0
	failedCount := 0

	for _, r := range results {
		fmt.Printf(
			"tool=%s version=%s backend=%s package_ref=%s status=%s install_ok=%t version_ok=%t checksum_ok=%t verify_mode=%s\n",
			r.Tool, r.Version, r.Backend, r.PackageRef, r.Status, r.InstallOK, r.VersionOK, r.ChecksumOK, r.VerifyMode,
		)
		if r.Warning != nil {
			fmt.Printf("tool=%s warning=%q\n", r.Tool, r.Warning.Error())
		}
		if r.Error != nil {
			fmt.Printf("tool=%s error=%q\n", r.Tool, r.Error.Error())
		}

		switch r.Status {
		case "ok":
			okCount++
		case "skipped":
			skippedCount++
		case "failed":
			failedCount++
		}
	}

	fmt.Printf("ok=%d skipped=%d failed=%d\n", okCount, skippedCount, failedCount)
	fmt.Println("INSTALL_TOOLS_POSIX_SUMMARY_END")
}

func fatal(stage string, err error) {
	fmt.Printf("stage=%s status=failed error=%q\n", stage, err.Error())
	os.Exit(1)
}
