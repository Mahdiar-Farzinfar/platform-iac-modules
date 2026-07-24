package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type Output struct {
	Modules []string `json:"modules"`
	Count   int      `json:"count"`
	Base    string   `json:"base"`
	Head    string   `json:"head"`
}

func main() {
	log.SetFlags(0)

	base := flag.String("base", "", "base git ref/sha")
	head := flag.String("head", "HEAD", "head git ref/sha")
	modulesDir := flag.String("modules-dir", "modules", "path to modules directory")
	flag.Parse()

	if strings.TrimSpace(*base) == "" {
		detected, err := detectBase()
		if err != nil {
			fatal("missing required --base and auto-detection failed: %v", err)
		}
		if detected == "" {
			files, err := listAllFiles()
			if err != nil {
				fatal("%v", err)
			}
			for _, f := range files {
				fmt.Println(f)
			}
			return
		}
		*base = detected
	}
	if strings.TrimSpace(*head) == "" {
		fatal("missing required --head")
	}

	// Ensure we are inside a git worktree.
	if err := ensureGitRepo(); err != nil {
		fatal("git repository check failed: %v", err)
	}

	// Validate refs early for clearer CI failures.
	if err := verifyCommitish(*base); err != nil {
		fatal("invalid --base ref %q: %v", *base, err)
	}
	if err := verifyCommitish(*head); err != nil {
		fatal("invalid --head ref %q: %v", *head, err)
	}

	changedFiles, err := changedPaths(*base, *head)
	if err != nil {
		fatal("failed to detect changed files: %v", err)
	}

	moduleSet := make(map[string]struct{})
	for _, p := range changedFiles {
		if mod, ok := extractTopLevelModule(p, *modulesDir); ok {
			moduleSet[mod] = struct{}{}
		}
	}

	// Keep only modules that currently exist as directories.
	// (if a module was removed, we don't include it in matrix jobs that require path existence)
	modules := make([]string, 0, len(moduleSet))
	for m := range moduleSet {
		if isDir(filepath.Join(*modulesDir, m)) {
			modules = append(modules, m)
		}
	}
	sort.Strings(modules)

	out := Output{
		Modules: modules,
		Count:   len(modules),
		Base:    *base,
		Head:    *head,
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fatal("failed to write json output: %v", err)
	}
}

// hasCommits reports whether the repository has at least one commit.
func hasCommits() bool {
	cmd := exec.Command("git", "rev-parse", "--verify", "HEAD")
	return cmd.Run() == nil
}

// listAllFiles returns every tracked + untracked file when the repo
// has no commit history yet, so there is nothing meaningful to diff.
func listAllFiles() ([]string, error) {
	out, err := exec.Command("git", "ls-files",
		"--cached", "--others", "--exclude-standard").Output()
	if err != nil {
		return nil, fmt.Errorf("failed to list files: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var files []string
	for _, l := range lines {
		if l != "" {
			files = append(files, l)
		}
	}
	return files, nil
}

func detectBase() (string, error) {
	if !hasCommits() {
		return "", nil
	}
	for _, ref := range []string{"origin/main", "origin/master"} {
		out, err := exec.Command("git", "rev-parse", ref).Output()
		if err == nil && len(strings.TrimSpace(string(out))) > 0 {
			return ref, nil
		}
	}
	out, err := exec.Command("git", "rev-parse", "HEAD~1").Output()
	if err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return "HEAD~1", nil
	}
	return "", errors.New("no suitable base ref found; please provide --base explicitly")
}

func ensureGitRepo() error {
	cmd := exec.Command("git", "rev-parse", "--is-inside-work-tree")
	out, err := cmd.Output()
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(out)) != "true" {
		return errors.New("not inside a git work tree")
	}
	return nil
}

func verifyCommitish(ref string) error {
	cmd := exec.Command("git", "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	if err := cmd.Run(); err != nil {
		return err
	}
	return nil
}

func changedPaths(base, head string) ([]string, error) {
	// -M -C handles rename/copy detection.
	// --name-only keeps output easy to parse.
	// three-dot (...) compares head against merge-base(base, head), ideal for PR flows.
	// For push flows base/head are usually linear and still works.
	rangeSpec := fmt.Sprintf("%s...%s", base, head)

	cmd := exec.Command("git", "diff", "--name-only", "-M", "-C", rangeSpec)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("git diff failed for %q: %s", rangeSpec, msg)
	}

	lines := strings.Split(stdout.String(), "\n")
	paths := make([]string, 0, len(lines))
	for _, l := range lines {
		p := normalizePath(strings.TrimSpace(l))
		if p == "" {
			continue
		}
		paths = append(paths, p)
	}
	return paths, nil
}

func extractTopLevelModule(path, modulesDir string) (string, bool) {
	p := normalizePath(path)
	root := normalizePath(modulesDir)
	prefix := root + "/"

	if !strings.HasPrefix(p, prefix) {
		return "", false
	}

	rest := strings.TrimPrefix(p, prefix)
	if rest == "" {
		return "", false
	}

	parts := strings.Split(rest, "/")
	if len(parts) == 0 || parts[0] == "" {
		return "", false
	}

	// Ignore files directly under modules/ (e.g., modules/README.md)
	if len(parts) == 1 {
		return "", false
	}

	return parts[0], true
}

func normalizePath(p string) string {
	p = strings.TrimSpace(p)
	p = filepath.ToSlash(p)
	p = strings.TrimPrefix(p, "./")
	return p
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false
		}
		// Conservative: on unexpected error, return false to avoid breaking matrix.
		return false
	}
	return info.IsDir()
}

func fatal(format string, args ...any) {
	log.Printf("ERROR: "+format, args...)
	os.Exit(1)
}
