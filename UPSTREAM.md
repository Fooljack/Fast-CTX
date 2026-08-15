# Upstream And Fork Provenance

This repository is a Windows-focused fork of FastCtx. It keeps the complete
upstream source tree and Apache-2.0 attribution.

- Upstream: `https://github.com/yc-duan/fastctx`
- Upstream tag: `v0.2.4`
- Upstream commit: `86dac0c99efae7859ed2be468f68c16e58f5e16a`
- Upstream commit date: `2026-08-02`
- Fork repository: `https://github.com/Fooljack/Fast-CTX`

## Source Hardening

The fork applies `docs/fastctx-local-hardening.patch` directly to the source.
The patch changes these files:

- `src/control/paths.rs`
- `src/read_tool/batch.rs`
- `src/read_tool/mod.rs`
- `src/runtime/mod.rs`
- `src/session.rs`
- `tests/glob_contract.rs`
- `tests/parent_watch_contract.rs`
- `tests/read_contract.rs`

The changes keep FastCtx state under the native Windows `USERPROFILE` when Git
Bash exports a different `HOME`, allow repeated paths in one batch read as
independent ranges, and treat Windows symlink error 1314 as an unavailable test
capability on unelevated systems. The remaining test-only changes remove timing
and formatting instability without changing tool behavior.

## Windows Integration Layer

The fork adds these files without mixing in unrelated Codex Desktop repair logic:

- `assets/fastctx-agent-guidance.md`
- `scripts/install-fastctx-windows.ps1`
- `scripts/configure-fastctx.ps1`
- `scripts/configure-agent-integrations.ps1`
- `scripts/configure-ccswitch-fastctx.ps1`
- `scripts/install-fastctx-from-github.ps1`
- `scripts/verify-fastctx-mcp.ps1`
- `scripts/test-agent-integrations.ps1`
- `scripts/test-ccswitch-integration.ps1`
- `scripts/test-github-bootstrap.ps1`
- `scripts/test-configure-fastctx-preserves-config.ps1`
- `scripts/test-configure-fastctx-verify-read-only.ps1`
- `scripts/test-windows-release-installer.ps1`
- `docs/install-windows-release.md`
- `docs/fastctx-windows-integration.md`
- `checksums/SHA256SUMS`

The installer does not run `fastctx apply` or `fastctx unapply`. It preserves
unrelated Codex configuration and user-authored global guidance, configures
Claude Code through its supported user-scope MCP CLI, refuses conflicting
same-name definitions unless force is explicit, and validates the prebuilt
binary before copying it to the stable user path. The Windows Release archive
contains the complete flat installer and an internal checksum manifest, so a
source checkout or Rust toolchain is not required.

## Updating From Upstream

1. Fetch the latest upstream commit and record its exact SHA.
2. Apply `docs/fastctx-local-hardening.patch` with `git apply --check` first.
3. Review every patch conflict instead of forcing it.
4. Run `cargo fmt --all -- --check` and `cargo test --locked` with a valid
   `FASTCTX_BASH` on custom Git installations.
5. Build `cargo build --locked --release`, replace the bundled Windows binary,
   and regenerate `checksums/SHA256SUMS`.
6. Run the configuration/guidance preservation tests, Claude conflict tests, the
   nine-tool MCP smoke, release-asset verification, and the flat Windows ZIP
   installation contract.
7. Remove temporary source clones, Cargo targets, fixture directories, logs, and
   test processes before committing.

Do not delete `~/.fastctx/jobs`, user settings, Codex config backups, or runtime
state belonging to active sessions as part of build cleanup.
