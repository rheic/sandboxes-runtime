package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestRepositoryManifest(t *testing.T) {
	root := filepath.Join("..", "..", "build")
	m, err := Load(filepath.Join(root, "manifest.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Verify(root); err != nil {
		t.Fatal(err)
	}
}

func TestGVProxyPatchHunkCounts(t *testing.T) {
	path := filepath.Join("..", "..", "build", "patches", "gvproxy-egress-policy-v2.patch")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	for i := 0; i < len(lines); {
		if !strings.HasPrefix(lines[i], "@@ ") {
			i++
			continue
		}
		oldWant, newWant, err := parsePatchHunkCounts(lines[i])
		if err != nil {
			t.Fatalf("patch line %d: %v", i+1, err)
		}
		oldCount, newCount := 0, 0
		j := i + 1
		for ; j < len(lines) && !strings.HasPrefix(lines[j], "@@ ") && !strings.HasPrefix(lines[j], "diff --git "); j++ {
			line := lines[j]
			if line == "" {
				t.Fatalf("patch line %d: unprefixed blank line inside hunk", j+1)
			}
			switch line[0] {
			case ' ':
				oldCount++
				newCount++
			case '-':
				oldCount++
			case '+':
				newCount++
			case '\\':
			default:
				t.Fatalf("patch line %d: invalid hunk line prefix %q", j+1, line[0])
			}
		}
		if oldCount != oldWant || newCount != newWant {
			t.Errorf("patch hunk at line %d declares %d/%d lines, contains %d/%d", i+1, oldWant, newWant, oldCount, newCount)
		}
		i = j
	}
}

func parsePatchHunkCounts(header string) (int, int, error) {
	fields := strings.Fields(header)
	if len(fields) < 4 {
		return 0, 0, fmt.Errorf("invalid hunk header %q", header)
	}
	count := func(value string) (int, error) {
		value = strings.TrimLeft(value, "-+")
		_, size, hasSize := strings.Cut(value, ",")
		if !hasSize {
			return 1, nil
		}
		return strconv.Atoi(size)
	}
	oldCount, err := count(fields[1])
	if err != nil {
		return 0, 0, fmt.Errorf("invalid old range in %q: %w", header, err)
	}
	newCount, err := count(fields[2])
	if err != nil {
		return 0, 0, fmt.Errorf("invalid new range in %q: %w", header, err)
	}
	return oldCount, newCount, nil
}

func TestNativeBuildScriptsUseManifestCommits(t *testing.T) {
	root := filepath.Join("..", "..")
	manifest, err := Load(filepath.Join(root, "build", "manifest.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	for script, component := range map[string]string{
		"scripts/build-containerd-linux-arm64.sh": "containerd",
		"scripts/build-nerdbox-shim.sh":           "nerdbox",
		"scripts/build-gvproxy.sh":                "gvisor-tap-vsock",
	} {
		commit := manifest.Components[component].Commit
		if commit == "" {
			t.Fatalf("manifest component %q has no commit", component)
		}
		data, err := os.ReadFile(filepath.Join(root, script))
		if err != nil {
			t.Fatal(err)
		}
		scriptText := string(data)
		if got := strings.Count(scriptText, "verify-pinned-source.sh"); got != 2 {
			t.Errorf("%s runs source verification %d times, want before and after copy", script, got)
		}
		for _, flag := range []string{"-trimpath", "-buildvcs=false", "-ldflags=-buildid="} {
			if !strings.Contains(scriptText, flag) {
				t.Errorf("%s is missing reproducible Go build flag %q", script, flag)
			}
		}
		if !strings.Contains(scriptText, commit) {
			t.Errorf("%s does not verify manifest commit %s", script, commit)
		}
	}
}

func TestLinuxLibkrunBuildPinsManifestInputs(t *testing.T) {
	root := filepath.Join("..", "..")
	manifest, err := Load(filepath.Join(root, "build", "manifest.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, "scripts", "build-libkrun-linux.sh"))
	if err != nil {
		t.Fatal(err)
	}
	scriptText := string(data)
	for _, component := range []string{"libkrun", "libkrunfw"} {
		dep := manifest.Components[component]
		pin := dep.Commit
		if pin == "" || !strings.Contains(scriptText, pin) {
			t.Errorf("Linux build script does not pin %s commit %q", component, pin)
		}
		if dep.Version == "" || !strings.Contains(scriptText, dep.Version) {
			t.Errorf("Linux build script does not pin %s version %q", component, dep.Version)
		}
		if dep.Source == "" || !strings.Contains(scriptText, dep.Source) {
			t.Errorf("Linux build script does not use %s source %q", component, dep.Source)
		}
	}
	kernel := manifest.Components["linux-kernel-arm64"]
	if kernel.SHA256 == "" || !strings.Contains(scriptText, kernel.SHA256) {
		t.Errorf("Linux build script does not verify kernel source digest %q", kernel.SHA256)
	}
	kernelSourceInScript := strings.Replace(kernel.Source, "linux-"+kernel.Version, "$KERNEL_VERSION", 1)
	if !strings.Contains(scriptText, kernel.Version) || !strings.Contains(scriptText, kernelSourceInScript) {
		t.Errorf("Linux build script does not use manifest kernel version/source %q / %q", kernel.Version, kernel.Source)
	}
	for _, flag := range []string{"BLK=1", "NET=1", "ARCH=arm64", "LIBKRUN_PREFIX must be empty"} {
		if !strings.Contains(scriptText, flag) {
			t.Errorf("Linux build script is missing required build constraint %q", flag)
		}
	}
	if !strings.Contains(scriptText, "nerdbox-kernel-arm64") || !strings.Contains(scriptText, "kernel_image_sha256=") {
		t.Error("Linux build script does not install and hash the kernel image required by nerdbox")
	}
	verifier, err := os.ReadFile(filepath.Join(root, "scripts", "verify-libkrun-linux-prefix.sh"))
	if err != nil {
		t.Fatal(err)
	}
	for _, commit := range []string{manifest.Components["libkrun"].Commit, manifest.Components["libkrunfw"].Commit} {
		if !strings.Contains(string(verifier), commit) {
			t.Errorf("prefix verifier does not check source commit %q", commit)
		}
	}
	if !strings.Contains(string(verifier), "nerdbox-kernel-arm64") || !strings.Contains(string(verifier), "verify_digest kernel_image") {
		t.Error("Linux prefix verifier does not validate the installed nerdbox kernel image")
	}
}

func TestVerifyComponentsRejectsMalformedSHA256(t *testing.T) {
	m := Manifest{Components: map[string]Component{
		"containerd":         {Version: "1", Source: "x"},
		"nerdbox":            {Version: "1", Source: "x"},
		"libkrun":            {Version: "1", Source: "x"},
		"libkrunfw":          {Version: "1", Source: "x"},
		"linux-kernel-arm64": {Version: "1", Source: "x", SHA256: "not-a-digest"},
		"gvisor-tap-vsock":   {Version: "1", Source: "x"},
	}}
	if err := m.verifyComponents(); err == nil {
		t.Fatal("expected malformed component SHA-256 error")
	}
}

func TestVerifyLinuxLibkrunPrefixRejectsArtifactAndMetadataDrift(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux prefix verifier requires sha256sum")
	}
	root := filepath.Join("..", "..")
	prefix := t.TempDir()
	libkrun := filepath.Join(prefix, "lib64", "libkrun.so.1.19.6")
	libkrunfw := filepath.Join(prefix, "lib", "aarch64-linux-gnu", "libkrunfw.so.5.6.2")
	kernelImage := filepath.Join(prefix, "nerdbox-kernel-arm64")
	libkrunBytes := []byte("synthetic libkrun artifact")
	libkrunfwBytes := []byte("synthetic libkrunfw artifact")
	kernelBytes := []byte("synthetic kernel image")
	for path, data := range map[string][]byte{libkrun: libkrunBytes, libkrunfw: libkrunfwBytes, kernelImage: kernelBytes} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	digest := func(data []byte) string {
		sum := sha256.Sum256(data)
		return hex.EncodeToString(sum[:])
	}
	info := strings.Join([]string{
		"libkrun_version=1.19.6",
		"libkrun_commit=227b2de6ed323fe180e02f871c5f325a90c13cc2",
		"libkrun_sha256=" + digest(libkrunBytes),
		"libkrunfw_version=5.6.2",
		"libkrunfw_commit=f14ac64ca8a04c6c9d76cac1c61ee050809c88c9",
		"libkrunfw_sha256=" + digest(libkrunfwBytes),
		"kernel_version=linux-6.12.109",
		"kernel_sha256=5484e552a334e15019f4aeba89e5b58f04651cf2f4e24e04de9f152f1c38e3fa",
		"kernel_image_sha256=" + digest(kernelBytes),
		"rustc_version=1.90.0",
		"gcc_version=13.3.0",
	}, "\n") + "\n"
	infoPath := filepath.Join(prefix, "share", "rheic-runtime", "libkrun-linux-arm64-build-info")
	if err := os.MkdirAll(filepath.Dir(infoPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(infoPath, []byte(info), 0o600); err != nil {
		t.Fatal(err)
	}
	verify := func() error {
		t.Helper()
		cmd := exec.Command("sh", filepath.Join(root, "scripts", "verify-libkrun-linux-prefix.sh"), prefix)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("prefix verifier failed: %w: %s", err, output)
		}
		return nil
	}
	if err := verify(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(libkrun, []byte("replaced artifact"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verify(); err == nil {
		t.Fatal("prefix verifier accepted a replaced library")
	}
	if err := os.WriteFile(libkrun, libkrunBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kernelImage, []byte("tampered kernel image"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verify(); err == nil {
		t.Fatal("prefix verifier accepted a replaced kernel image")
	}
	if err := os.WriteFile(kernelImage, kernelBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(infoPath, []byte(info+"libkrun_version=1.19.7\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verify(); err == nil {
		t.Fatal("prefix verifier accepted a duplicate pinned metadata field")
	}
}

func TestBuildLinuxLibkrunRejectsNonEmptyPrefix(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux build script uses find -mindepth")
	}
	root := filepath.Join("..", "..")
	prefix := t.TempDir()
	marker := filepath.Join(prefix, "keep.txt")
	if err := os.WriteFile(marker, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", filepath.Join(root, "scripts", "build-libkrun-linux.sh"))
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LIBKRUN_PREFIX=" + prefix}
	output, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(output), "LIBKRUN_PREFIX must be empty") {
		t.Fatalf("expected non-empty prefix refusal, got err=%v output=%s", err, output)
	}
	if got, err := os.ReadFile(marker); err != nil || string(got) != "preserve" {
		t.Fatalf("existing prefix content changed: got %q, err=%v", got, err)
	}
}

func TestPinnedSourceRejectsIgnoredFiles(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	root := t.TempDir()
	runGit := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
		return strings.TrimSpace(string(output))
	}
	runGit("init", "-q")
	runGit("config", "user.name", "runtime-test")
	runGit("config", "user.email", "runtime-test@example.invalid")
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("generated.go\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tracked.txt"), []byte("pinned source\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit("add", ".gitignore", "tracked.txt")
	runGit("commit", "-m", "test pinned source")
	commit := runGit("rev-parse", "HEAD")
	if err := os.WriteFile(filepath.Join(root, "generated.go"), []byte("package injected\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join("..", "..", "scripts", "verify-pinned-source.sh")
	cmd := exec.Command(script, root, commit)
	if output, err := cmd.CombinedOutput(); err == nil {
		t.Fatalf("preflight accepted an ignored source file: %s", output)
	}
}

func TestPinnedSourceAcceptsCleanCheckout(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	root, commit := initPinnedSourceRepo(t)
	if output := runPinnedSourceVerifier(t, root, commit, nil); output != nil {
		t.Fatalf("preflight rejected a clean pinned checkout: %s", output)
	}
}

func TestPinnedSourceRejectsGitIndexFlags(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	for _, flag := range []string{"--skip-worktree", "--assume-unchanged"} {
		t.Run(flag, func(t *testing.T) {
			root, commit := initPinnedSourceRepo(t)
			gitTestCommand(t, root, "update-index", flag, "tracked.go")
			if err := os.WriteFile(filepath.Join(root, "tracked.go"), []byte("package main\nvar changed = true\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if output := runPinnedSourceVerifier(t, root, commit, nil); output == nil {
				t.Fatal("preflight accepted modified source hidden by an index flag")
			}
		})
	}
}

func TestPinnedSourceBindsGitWorktreeToCopiedDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	root, commit := initPinnedSourceRepo(t)
	checkout := filepath.Join(t.TempDir(), "checkout")
	gitTestCommand(t, filepath.Dir(root), "clone", "-q", root, checkout)
	gitTestCommand(t, checkout, "config", "core.worktree", root)
	if err := os.WriteFile(filepath.Join(checkout, "injected.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if output := runPinnedSourceVerifier(t, checkout, commit, nil); output == nil {
		t.Fatal("preflight followed core.worktree instead of checking the copied checkout")
	}
}

func TestPinnedSourceIgnoresInheritedGitWorktree(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	root, commit := initPinnedSourceRepo(t)
	other := filepath.Join(t.TempDir(), "other")
	gitTestCommand(t, filepath.Dir(root), "clone", "-q", root, other)
	if err := os.WriteFile(filepath.Join(root, "injected.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	env := []string{"GIT_DIR=" + filepath.Join(other, ".git"), "GIT_WORK_TREE=" + other}
	if output := runPinnedSourceVerifier(t, root, commit, env); output == nil {
		t.Fatal("preflight followed inherited Git environment instead of checking the source directory")
	}
}

func TestPinnedSourceRejectsConfiguredGitFilters(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	root, commit := initPinnedSourceRepo(t)
	gitTestCommand(t, root, "config", "filter.synthetic.clean", "cat")
	if output := runPinnedSourceVerifier(t, root, commit, nil); output == nil {
		t.Fatal("preflight accepted a checkout with an unpinned Git filter")
	}
}

func TestPinnedSourceRejectsIgnoredSubmoduleChanges(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native source preflight is a POSIX shell script")
	}
	root, submoduleCommit := initPinnedSourceRepo(t)
	gitmodules := "[submodule \"synthetic\"]\n\tpath = injected\n\turl = synthetic://local\n\tignore = all\n"
	if err := os.WriteFile(filepath.Join(root, ".gitmodules"), []byte(gitmodules), 0o600); err != nil {
		t.Fatal(err)
	}
	gitTestCommand(t, root, "add", ".gitmodules")
	gitTestCommand(t, root, "update-index", "--add", "--cacheinfo", "160000,"+submoduleCommit+",injected")
	gitTestCommand(t, root, "commit", "-m", "add ignored synthetic submodule")
	commit := gitTestCommand(t, root, "rev-parse", "HEAD")
	submodule := filepath.Join(root, "injected")
	if err := os.Mkdir(submodule, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(submodule, "injected.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if output := runPinnedSourceVerifier(t, root, commit, nil); output == nil {
		t.Fatal("preflight accepted source hidden by a submodule ignore rule")
	}
}

func initPinnedSourceRepo(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	gitTestCommand(t, root, "init", "-q")
	gitTestCommand(t, root, "config", "user.name", "runtime-test")
	gitTestCommand(t, root, "config", "user.email", "runtime-test@example.invalid")
	if err := os.WriteFile(filepath.Join(root, "tracked.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitTestCommand(t, root, "add", "tracked.go")
	gitTestCommand(t, root, "commit", "-m", "test pinned source")
	return root, gitTestCommand(t, root, "rev-parse", "HEAD")
}

func gitTestCommand(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, output)
	}
	return strings.TrimSpace(string(output))
}

func runPinnedSourceVerifier(t *testing.T, root, commit string, gitEnv []string) []byte {
	t.Helper()
	script := filepath.Join("..", "..", "scripts", "verify-pinned-source.sh")
	cmd := exec.Command(script, root, commit)
	if gitEnv != nil {
		for _, entry := range os.Environ() {
			if !strings.HasPrefix(entry, "GIT_") {
				cmd.Env = append(cmd.Env, entry)
			}
		}
		cmd.Env = append(cmd.Env, gitEnv...)
	}
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	return output
}

func FuzzParseManifest(f *testing.F) {
	f.Add([]byte("version: 1\nplatforms: [linux/arm64]\n"))
	f.Add([]byte("components: ["))
	f.Add([]byte(""))
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = parseManifest(data)
	})
}

func TestVerifyRejectsMissingPatch(t *testing.T) {
	root := t.TempDir()
	m := Manifest{
		Version: 1,
		Components: map[string]Component{
			"containerd":         {Version: "1", Source: "x"},
			"nerdbox":            {Version: "1", Source: "x"},
			"libkrun":            {Version: "1", Source: "x"},
			"libkrunfw":          {Version: "1", Source: "x"},
			"linux-kernel-arm64": {Version: "1", Source: "x"},
			"gvisor-tap-vsock":   {Version: "1", Source: "x"},
		},
		Patches: map[string]Patch{
			"missing": {File: "missing.patch", SHA256: "00"},
		},
	}
	if err := m.Verify(root); err == nil {
		t.Fatal("expected missing patch error")
	}
}

func TestVerifyRejectsUnpinnedImage(t *testing.T) {
	root := t.TempDir()
	patch := filepath.Join(root, "p.patch")
	if err := os.WriteFile(patch, []byte("ok"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := Manifest{
		Version: 1,
		Components: map[string]Component{
			"containerd":         {Version: "1", Source: "x"},
			"nerdbox":            {Version: "1", Source: "x"},
			"libkrun":            {Version: "1", Source: "x"},
			"libkrunfw":          {Version: "1", Source: "x"},
			"linux-kernel-arm64": {Version: "1", Source: "x"},
			"gvisor-tap-vsock":   {Version: "1", Source: "x"},
		},
		Patches: map[string]Patch{
			"p": {File: "p.patch", SHA256: "2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df"},
		},
		Images: map[string]Image{
			"default": {Ref: "x", Digest: "latest"},
		},
	}
	if err := m.Verify(root); err == nil {
		t.Fatal("expected image pin error")
	}
}
