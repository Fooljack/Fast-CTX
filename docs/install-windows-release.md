# Install FastCtx on Windows

This archive is self-contained for Windows x64. It installs the prebuilt `fastctx.exe`; Rust, Cargo, and Node.js are not required.

## Give an AI agent only the repository link

Repository:

```text
https://github.com/Fooljack/Fast-CTX
```

This repository is currently private. The target computer must already have permission to read it
(for example, an authenticated GitHub credential or organization access) for the raw bootstrap and
Release URLs to work. The link alone is sufficient for anonymous installation only if the repository
is made public; the installer never collects credentials.

An agent can install the latest verified Windows Release without cloning or compiling the repository. It should download the bootstrap script as a file, inspect it if required by local policy, and then execute it. Do not pipe remote PowerShell directly into `Invoke-Expression`.

```powershell
$bootstrap = Join-Path $env:TEMP 'install-fastctx-from-github.ps1'
Invoke-WebRequest `
  'https://raw.githubusercontent.com/Fooljack/Fast-CTX/main/scripts/install-fastctx-from-github.ps1' `
  -OutFile $bootstrap
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap
```

The bootstrap follows GitHub's latest stable Release download redirect (or an explicitly pinned tag), downloads exactly `fastctx-x86_64-pc-windows-msvc.zip` and the Release-level `SHA256SUMS` from constructed HTTPS GitHub URLs, verifies SHA-256, extracts into a unique temporary directory, and runs the packaged installer without calling the rate-limited GitHub API. Pin a published version when reproducibility is more important than following `latest`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File $bootstrap -Tag v0.3.0
```

## Prerequisites

- Windows 10 or newer, x64.
- Git for Windows, including Git Bash.
- Claude Code if you want automatic Claude Code MCP registration. Codex can be configured before or after its CLI is installed.
- Optional: CC Switch. Update it to v3.19.0 or newer before accepting MCP deep links so its confirmation dialog displays the complete command, arguments, URL, and environment with credential-shaped values masked.

## Verify a manual download

Download the archive and the Release-level `SHA256SUMS` file from the same GitHub Release, then compare:

```powershell
certutil -hashfile .\fastctx-x86_64-pc-windows-msvc.zip SHA256
Select-String 'fastctx-x86_64-pc-windows-msvc.zip' .\SHA256SUMS
```

After extraction, the archive's own `SHA256SUMS` lists every flat payload file. The installer authenticates
that complete set—including its helpers and guidance—before executing any packaged script, then
independently verifies the bundled executable before publishing it to the stable user path.

## Install from an extracted ZIP

Open PowerShell in the extracted directory and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install-fastctx-windows.ps1
```

The default installation:

- copies the executable to `~\.fastctx\bin\fastctx.exe`;
- registers the exact nine-tool stdio server for Claude Code at user scope;
- writes only the FastCtx tables in `~\.codex\config.toml`, preserving unrelated TOML;
- applies the verified standard token budgets (`54000`, `10800`, `5400`, `10800`, `5400`);
- inserts or updates only the `<!-- fastctx:begin -->` … `<!-- fastctx:end -->` block in effective global instruction files;
- uses `CLAUDE_CONFIG_DIR` when set and a non-empty `AGENTS.override.md` before `AGENTS.md` for Codex;
- runs an MCP initialize handshake and requires exactly `read`, `grep`, `glob`, `replace`, `run`, `run_background`, `job_list`, `job_output`, and `job_kill`;
- when the `ccswitch://` protocol is registered, opens CC Switch's official import confirmation for Claude, Codex, Gemini, Grok Build, OpenCode, and Hermes.

CC Switch keeps MCP servers in one application-level database and deliberately excludes them from individual provider snapshots. Importing once with all six application flags is therefore the correct way to keep FastCtx available while switching providers; copying MCP text into every provider would create stale duplicates. The installer never edits `~/.cc-switch/cc-switch.db` directly and never bypasses the CC Switch confirmation. Review the displayed `fastctx.exe serve --enable-shell` command and environment, then click **Import**. If an entry named `fastctx` already exists, CC Switch preserves that existing server definition while merging additional application flags; inspect or replace a stale entry in CC Switch before relying on it.

CC Switch controls:

```powershell
# Configure Claude Code and Codex but do not involve CC Switch
.\install-fastctx-windows.ps1 -SkipCcSwitch

# Validate/generate the CC Switch payload without opening another application
.\install-fastctx-windows.ps1 -NoLaunchCcSwitch

# Fail installation unless ccswitch:// is registered
.\install-fastctx-windows.ps1 -RequireCcSwitch
```

If CC Switch is installed later, rerun the normal installer to open the import confirmation. A different existing Claude Code or Codex MCP definition named `fastctx` is never overwritten silently. Review it first, then use `-ForceMcpRegistration` only when replacement is intentional. Use `-ForceBinary` only when you intentionally want to republish the stable executable even if the normal hash comparison would keep it.

If Claude Code is intentionally not installed, keep Codex and optional CC Switch integration while skipping only Claude registration and guidance:

```powershell
.\install-fastctx-windows.ps1 -SkipClaudeCode
```

## Verify later

From the extracted directory or through the repository-link bootstrap:

```powershell
.\install-fastctx-windows.ps1 -VerifyOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -VerifyOnly
```

Verification is read-only and checks the installed binary, Claude/Codex configuration, global guidance, initialize response, and exact tool manifest. It confirms whether `ccswitch://` is registered but intentionally does not inspect or modify CC Switch's SQLite database. Restart installed MCP clients after installation so new sessions load FastCtx and its global guidance.

## Optional source build

A source build is never selected implicitly. In a repository checkout with Rust 1.88 or newer, request it explicitly:

```powershell
.\scripts\install-fastctx-windows.ps1 -BuildFromSource
```

The Release ZIP does not contain the Rust source tree; use its prebuilt executable instead.
