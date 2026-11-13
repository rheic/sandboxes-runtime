# Changelog

## Unreleased

### Security and limitations

- Add an experimental Linux/ARM64 containerd v2.4.2 build with fail-closed,
  mount-boundary-aware bundle cleanup. The prototype has rootful Ubuntu ARM64
  VM controls; native Linux, rootless, concurrent same-UID mount-race,
  artifact-signing and daemon-installation acceptance remain open.

## v0.0.30 — 2026-11-10

### Added

- Add pinned Linux ARM64 libkrun and nerdbox shim build recipes, runtime
  manifest checks, and a deterministic EROFS guest-rootfs recipe.
- Restrict the experimental Linux guest network helper to `NETLINK_ROUTE` and
  clean host rootfs mounts after successful VM shutdown and after abrupt shim
  death through containerd's bundle-scoped delete action.
- Restrict VM runtime asset lookup to explicit `LIBKRUN_PATH` or fixed system
  directories; the shim builder publishes output atomically without following
  symlink destinations.
- Pin Go 1.27.4 for runtime builds and verify the signed crun 1.30.1 guest
  runtime release by checksum before embedding it in the EROFS image.

### Security and limitations

- Linux runtime support remains experimental. Acceptance is limited to a
  privileged rootful workflow in a macOS-hosted Ubuntu ARM64 VM; native Linux,
  ordinary-user and rootless acceptance remain open. Windows runtime is out of
  scope.
- Runtime build-image pinning, signed provenance, independent security review
  and full Docker Sandboxes parity remain open. Abrupt-shim cleanup has been
  verified for an owned EROFS bundle in a privileged rootful Linux ARM64 VM;
  native Linux and ordinary-user/rootless acceptance remain open.
- Runtime assets are not digest-verified at load time; configured and default
  host asset directories must remain protected from untrusted writes.
- The guest crun update addresses the upstream rootfs `/dev` symlink advisory
  affecting versions before 1.28. The latest upstream release is used because
  crun is security-sensitive guest runtime code; its release asset and
  checksum list signatures are verified against the pinned upstream key.

## v0.0.20 — 2026-11-03

### Added

- Add a read-only guest proxy-helper mount and supervised startup through the optional runtime capability.
- Publish a CycloneDX module SBOM as a CI artifact.

### Security

- Harden pinned native-source verification against ignored files, hidden index flags, redirected worktrees, local Git configuration, and submodules.
- Normalize native build metadata for repeatable same-host artifact digests.

### Changed

- Normalize the Go module path to the lowercase `github.com/quoiner/sandboxes-runtime` namespace.
- Update `golang.org/x/net` to v0.62.0.
