# Fast-CTX: Codex Windows Patch Chain

This repository is the Fooljack verified wrapper/archive for the upstream skill:

```text
https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill
```

Use it on a new Windows machine after cloning `https://github.com/Fooljack/Fast-CTX.git`.

## Run From Checkout

```powershell
git clone https://github.com/Fooljack/Fast-CTX.git
cd Fast-CTX
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\configure-fastctx.ps1"
# Restart Codex Desktop once so it loads the FastCtx MCP configuration.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-latest-fast-patch.ps1" -SkillDir (Get-Location).ProviderPath -ReportCheckout (Get-Location).ProviderPath
```

The wrapper pulls the latest upstream skill first, reapplies Fooljack's local hardening overlay, repairs the Codex Desktop MSIX, then writes a verified run record. Its default archive remote is this `Fast-CTX` repository, so a clean run never redirects to the retired `Codex-settings` archive.

By default, only a clean run is archived and pushed to `main`. Failed runs remain in the local `%USERPROFILE%\.codex\codex-windows-fast-patch-runs` folder for debugging and are not pushed unless `-PublishOnProblems` is explicitly used.

## FastCtx One-Time Setup

Install FastCtx, then run the repository configurator once before restarting Codex Desktop:

```powershell
npm install --global fastctx
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\configure-fastctx.ps1"
```

For a locally hardened binary, pass its absolute path with `-FastCtxBinary`. The script copies it to `%USERPROFILE%\.fastctx\bin\fastctx.exe` and replaces that stable copy when its SHA-256 differs. It backs up the existing Codex config and only updates the FastCtx MCP tables. It fixes `HOME`, `USERPROFILE`, and `CODEX_HOME` so Git Bash cannot move FastCtx state into the Git installation directory. It does not run `fastctx apply` or `fastctx unapply`.

`-VerifyOnly` is read-only for the configured files and does not create missing roots. It validates both TOML files, runs `fastctx status`, and performs an MCP `initialize`/`tools/list` handshake that must return exactly the nine FastCtx tools.

Read `references\fastctx-windows-integration.md` for architecture, nine-tool verification, fallback policy, source patches, and the cleanup boundary. Background job records and required runtime caches are persistent state; per-run clone/build/test/log artifacts are removed after validation.

## What The Chain Covers

- Fast Mode UI/request gates and final wire verification for `service_tier=priority`.
- Chinese/locale i18n gates.
- Plugin UI gates, bundled marketplace wiring, and local `openai-bundled` registration.
- `computer-use`, `browser`, and `chrome` bundled plugins.
- Chrome native messaging host path pinned to a stable versioned cache path.
- Windows Computer Use availability and helper transport verification.
- Current Store CLI/CUA copied by data stream into marked user-local runtime directories when Desktop no longer extracts matching copies itself.
- `[windows] sandbox = "unelevated"` and a CLI sandbox smoke test.
- WindowsApps long-path/data-only copy fallback for Store package files.
- Developer signing/installing patched MSIX packages and safe `shell:AppsFolder` app launch.

## Correct Sandbox Command

Do not hard-code the legacy sandbox subcommand form. Current CLI builds use:

```powershell
codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK
```

Older builds may still expose a legacy `windows` subcommand. `scripts\run-latest-fast-patch.ps1` auto-detects the correct form from `codex sandbox --help` and records the command that actually ran.

## Verification Artifacts

Successful runs write:

```text
%USERPROFILE%\.codex\codex-windows-fast-patch-runs\latest.md
reports\latest.md
reports\runs\<timestamp>.md
```

Reports are sanitized. Do not commit raw logs, certificates, `config.toml`, auth files, tokens, or local environment files.

Pushing a clean run requires that Git is authenticated for the `Fooljack` account on that PC. The repair itself can complete without a GitHub credential; an unauthenticated archive push is recorded locally and is not treated as a verified published result.

When a clean run is archived, `scripts\publish-verified-chain.ps1` also prunes stale run reports under `reports\runs` that contain recorded problems, the legacy hard-coded sandbox command, or malformed old code fences. `reports\latest.md` is always replaced with the latest clean run.
