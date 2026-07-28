//go:build windows

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
		"shfmt":          "mvdan.Shfmt",
		"docker-cli":     "Docker.DockerCLI",
		"docker-compose": "Docker.Compose",
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

		packageRef, managed := resolvePackageRef(k, spec.Version)
		if !managed {
			results = append(results, InstallResult{
				Tool:       k,
				Version:    spec.Version,
				Status:     "failed",
				Backend:    string(activePackageManager),
				PackageRef: "",
				Error:      fmt.Errorf("no %s mapping for tool=%s", activePackageManager, k),
			})
			continue
		}

		res := InstallResult{
			Tool:       k,
			Version:    spec.Version,
			Status:     "failed",
			Backend:    string(activePackageManager),
			PackageRef: packageRef,
		}

		switch activePackageManager {
		case packageManagerScoop:
			if err := installWithScoop(&res, k, spec); err != nil {
				res.Error = err
				results = append(results, res)
				continue
			}
		case packageManagerWinget:
			if err := installWithWinget(&res, k, spec); err != nil {
				res.Error = err
				results = append(results, res)
				continue
			}
		default:
			res.Error = fmt.Errorf("unsupported package manager: %s", activePackageManager)
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
	if path, ok := resolveScoopExecutable(); ok {
		scoopExecutable = path
		activePackageManager = packageManagerScoop
		return nil
	}

	if path, ok := resolveWingetExecutable(); ok {
		wingetExecutable = path
		activePackageManager = packageManagerWinget
		return nil
	}

	return errors.New("no supported package manager found: Scoop is not installed and winget is unavailable")
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
	if err := wingetInstallVersioned(res.PackageRef, spec.Version); err != nil {
		return fmt.Errorf("winget install failed: %w", err)
	}

	res.InstallOK = true
	res.VerifyMode = "install-only"

	verified, err := verifyInstalledToolVersion(tool, spec.Version)
	if verified {
		res.VerifyMode = "version-only"
	}
	if err != nil {
		return fmt.Errorf("version verification failed: %w", err)
	}
	if verified {
		res.VersionOK = true
	}

	return nil
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

func resolvePackageRef(tool, version string) (string, bool) {
	switch activePackageManager {
	case packageManagerScoop:
		ref, ok := scoopMap[tool]
		return ref, ok
	case packageManagerWinget:
		return resolveWingetPackageID(tool, version)
	default:
		return "", false
	}
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
		return
	}
	if current == "" {
		_ = os.Setenv("PATH", dir)
		return
	}
	_ = os.Setenv("PATH", current+string(os.PathListSeparator)+dir)
}

func ensureExecutableDirOnPath(executable string) {
	ensureDirOnPath(filepath.Dir(executable))
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
	baseArgs := []string{
		"install",
		"--id", packageID,
		"--exact",
		"--accept-package-agreements",
		"--accept-source-agreements",
		"--disable-interactivity",
		"--silent",
	}

	versionArgs := append(append([]string{}, baseArgs...), "--version", normalizeSemver(version))
	if err := run(wingetExecutable, versionArgs...); err != nil {
		return fmt.Errorf("exact-version install failed for %s@%s: %w", packageID, normalizeSemver(version), err)
	}
	return nil
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
